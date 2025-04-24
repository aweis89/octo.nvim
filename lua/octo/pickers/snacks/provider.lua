local gh = require "octo.gh"
local graphql = require "octo.gh.graphql"
local queries = require "octo.gh.queries"
local utils = require "octo.utils"
local octo_config = require "octo.config"
local navigation = require "octo.navigation"
local Snacks = require "snacks"

local M = {}

--- Builds the key mappings and merged actions for the Snacks picker.
---@param hardcoded_actions table<string, function> The actions defined directly in the provider function.
---@param cfg OctoConfig The global Octo configuration.
---@return { keys: table, actions: table }
local function build_snacks_config(hardcoded_actions, cfg)
  local snacks_cfg = cfg.snacks_picker or {} -- Get snacks config, default to empty table if nil
  local custom_actions = snacks_cfg.custom_actions or {}

  local input_keys = {}
  -- Start with a deep copy of hardcoded actions to avoid modifying the original
  local merged_actions = vim.deepcopy(hardcoded_actions)

  -- Process custom actions
  for action_name, definition in pairs(custom_actions) do
    if definition.lhs and definition.action then
      input_keys[definition.lhs] = { action_name, mode = { "n", "i" } }
      -- Add the custom action function to the merged actions
      merged_actions[action_name] = definition.action
    end
  end

  return { keys = input_keys, actions = merged_actions }
end

local function get_filter(opts, kind)
  local filter = ""
  local allowed_values = {}
  if kind == "issue" then
    allowed_values = { "since", "createdBy", "assignee", "mentioned", "labels", "milestone", "states" }
  elseif kind == "pull_request" then
    allowed_values = { "baseRefName", "headRefName", "labels", "states" }
  end

  for _, value in pairs(allowed_values) do
    if opts[value] then
      local val
      if #vim.split(opts[value], ",") > 1 then
        -- list
        val = vim.split(opts[value], ",")
      else
        -- string
        val = opts[value]
      end
      val = vim.json.encode(val)
      val = string.gsub(val, '"OPEN"', "OPEN")
      val = string.gsub(val, '"CLOSED"', "CLOSED")
      val = string.gsub(val, '"MERGED"', "MERGED")
      filter = filter .. value .. ":" .. val .. ","
    end
  end

  return filter
end

function M.not_implemented()
  utils.error "Not implemented yet"
end

M.issues = function(opts)
  opts = opts or {}
  if not opts.states then
    opts.states = "OPEN"
  end
  local filter = get_filter(opts, "issue")
  if utils.is_blank(opts.repo) then
    opts.repo = utils.get_remote_name()
  end
  if not opts.repo then
    utils.error "Cannot find repo"
    return
  end

  local owner, name = utils.split_repo(opts.repo)
  local cfg = octo_config.values
  local order_by = cfg.issues.order_by
  local query = graphql("issues_query", owner, name, filter, order_by.field, order_by.direction, { escape = false })
  utils.info "Fetching issues (this may take a while) ..."
  gh.run {
    args = { "api", "graphql", "--paginate", "--jq", ".", "-f", string.format("query=%s", query) },
    cb = function(output, stderr)
      if stderr and not utils.is_blank(stderr) then
        utils.error(stderr)
      elseif output then
        local resp = utils.aggregate_pages(output, "data.repository.issues.nodes")
        local issues = resp.data.repository.issues.nodes
        if #issues == 0 then
          utils.error(string.format("There are no matching issues in %s.", opts.repo))
          return
        end
        local max_number = -1
        for _, issue in ipairs(issues) do
          if issue.number > max_number then
            max_number = issue.number
          end
          issue.text = string.format("#%d %s", issue.number, issue.title)
          issue.file = utils.get_issue_uri(issue.number, issue.repository.nameWithOwner)
          issue.kind = issue.__typename:lower()
        end

        -- Define the hardcoded actions available for *this* picker
        local hardcoded_actions = {
          open_in_browser = function(_picker, item)
            navigation.open_in_browser(item.kind, item.repository.nameWithOwner, item.number)
          end,
          copy_url = function(_picker, item)
            local url = item.url
            utils.copy_url(url)
          end,
          -- Add other issue-specific actions here if needed in the future
        }

        -- Build the keys and merged actions using the helper
        local snacks_config = build_snacks_config(hardcoded_actions, cfg)

        Snacks.picker.pick {
          title = opts.preview_title or "",
          items = issues,
          format = function(item, _)
            ---@type snacks.picker.Highlight[]
            local ret = {}
            ---@diagnostic disable-next-line: assign-type-mismatch
            ret[#ret + 1] = utils.get_icon { kind = item.kind, obj = item }
            ret[#ret + 1] = { string.format("#%d", item.number), "Comment" }
            ret[#ret + 1] = { (" "):rep(#tostring(max_number) - #tostring(item.number) + 1) }
            ret[#ret + 1] = { item.title, "Normal" }
            return ret
          end,
          win = {
            input = {
              -- Use the generated keys
              keys = snacks_config.keys,
            },
          },
          -- Pass the merged actions (hardcoded + custom)
          actions = snacks_config.actions,
        }
      end
    end,
  }
end

function M.pull_requests(opts)
  opts = opts or {}
  if not opts.states then
    opts.states = "OPEN"
  end
  local filter = get_filter(opts, "pull_request")
  if utils.is_blank(opts.repo) then
    opts.repo = utils.get_remote_name()
  end
  if not opts.repo then
    utils.error "Cannot find repo"
    return
  end

  local owner, name = utils.split_repo(opts.repo)
  local cfg = octo_config.values
  local order_by = cfg.pull_requests.order_by
  local query =
    graphql("pull_requests_query", owner, name, filter, order_by.field, order_by.direction, { escape = false })
  utils.info "Fetching pull requests (this may take a while) ..."
  gh.run {
    args = { "api", "graphql", "--paginate", "--jq", ".", "-f", string.format("query=%s", query) },
    cb = function(output, stderr)
      if stderr and not utils.is_blank(stderr) then
        utils.error(stderr)
      elseif output then
        local resp = utils.aggregate_pages(output, "data.repository.pullRequests.nodes")
        local pull_requests = resp.data.repository.pullRequests.nodes
        if #pull_requests == 0 then
          utils.error(string.format("There are no matching pull requests in %s.", opts.repo))
          return
        end
        local max_number = -1
        for _, pull in ipairs(pull_requests) do
          if pull.number > max_number then
            max_number = pull.number
          end
          pull.text = string.format("#%d %s", pull.number, pull.title)
          pull.file = utils.get_pull_request_uri(pull.number, pull.repository.nameWithOwner)
          pull.kind = pull.__typename:lower() == "pullrequest" and "pull_request" or "unknown"
        end

        -- Define the hardcoded actions available for *this* picker
        local hardcoded_actions = {
          open_in_browser = function(_picker, item)
            navigation.open_in_browser(item.kind, item.repository.nameWithOwner, item.number)
          end,
          copy_url = function(_picker, item)
            utils.copy_url(item.url)
          end,
          checkout_pr = function(_picker, item)
            utils.checkout_pr(item.number)
          end,
          merge_pr = function(_picker, item)
            utils.merge_pr(item.number)
          end,
        }

        -- Build the keys and merged actions using the helper
        local snacks_config = build_snacks_config(hardcoded_actions, cfg)

        Snacks.picker.pick {
          title = opts.preview_title or "",
          items = pull_requests,
          format = function(item, _)
            ---@type snacks.picker.Highlight[]
            local ret = {}
            ---@diagnostic disable-next-line: assign-type-mismatch
            ret[#ret + 1] = utils.get_icon { kind = item.kind, obj = item }
            ret[#ret + 1] = { string.format("#%d", item.number), "Comment" }
            ret[#ret + 1] = { (" "):rep(#tostring(max_number) - #tostring(item.number) + 1) }
            ret[#ret + 1] = { item.title, "Normal" }
            return ret
          end,
          win = {
            input = {
              -- Use the generated keys
              keys = snacks_config.keys,
            },
          },
          -- Pass the merged actions (hardcoded + custom)
          actions = snacks_config.actions,
        }
      end
    end,
  }
end

function M.notifications(opts)
  opts = opts or {}
  local cfg = octo_config.values

  local endpoint = "/notifications"
  if opts.repo then
    local owner, name = utils.split_repo(opts.repo)
    endpoint = string.format("/repos/%s/%s/notifications", owner, name)
  end
  opts.prompt_title = opts.repo and string.format("%s Notifications", opts.repo) or "Github Notifications"

  opts.preview_title = ""
  opts.results_title = ""

  gh.run {
    args = { "api", "--paginate", endpoint },
    headers = { "Accept: application/vnd.github.v3.diff" },
    cb = function(output, stderr)
      if stderr and not utils.is_blank(stderr) then
        utils.error(stderr)
      elseif output then
        local notifications = vim.json.decode(output)

        if #notifications == 0 then
          utils.info "There are no notifications"
          return
        end

        local safe_notifications = {}

        for _, notification in ipairs(notifications) do
          local safe = false
          notification.subject.number = notification.subject.url:match "%d+$"
          notification.text = string.format("#%d %s", notification.subject.number, notification.subject.title)
          notification.kind = notification.subject.type:lower()
          if notification.kind == "pullrequest" then
            notification.kind = "pull_request"
          end
          notification.status = notification.unread and "unread" or "read"
          if notification.kind == "issue" then
            notification.file = utils.get_issue_uri(notification.subject.number, notification.repository.full_name)
            safe = true
          elseif notification.kind == "pull_request" then
            notification.file =
              utils.get_pull_request_uri(notification.subject.number, notification.repository.full_name)
            safe = true
          end
          if safe then
            safe_notifications[#safe_notifications + 1] = notification
          end
        end

        -- Define hardcoded actions including the notification-specific one
        local hardcoded_actions = {
          open_in_browser = function(_picker, item)
            navigation.open_in_browser(item.kind, item.repository.full_name, item.subject.number)
          end,
          copy_url = function(_picker, item)
            utils.copy_url(item.url) -- Assuming item.url exists for notifications? Check API if needed.
          end,
          mark_notification_read = function(picker, item)
            local url = string.format("/notifications/threads/%s", item.id)
            gh.run {
              args = { "api", "--method", "PATCH", url },
              headers = { "Accept: application/vnd.github.v3.diff" },
              cb = function(_, stderr)
                if stderr and not utils.is_blank(stderr) then
                  utils.error(stderr)
                  return
                end
              end,
            }
            -- TODO: No current way to redraw the list/remove just this item
            picker:close()
            M.notifications(opts) -- Refresh list
          end,
        }

        -- Build the base config from hardcoded and custom actions
        local snacks_config = build_snacks_config(hardcoded_actions, cfg)

        -- Check if the user *re-mapped* the notification read action specifically
        -- using the main mappings table (as it's not part of the generic picker mappings)
        local read_mapping = cfg.mappings.notification.read
        if read_mapping and read_mapping.lhs then
          -- If the user defined a specific key in the main mappings section for this, use it.
          -- This overrides any potential mapping from custom_actions if the name collided.
          snacks_config.keys[read_mapping.lhs] = { "mark_notification_read", mode = { "n", "i" } }
        end

        Snacks.picker.pick {
          title = opts.preview_title or "",
          items = safe_notifications,
          format = function(item, _)
            ---@type snacks.picker.Highlight[]
            local ret = {}
            ---@diagnostic disable-next-line: assign-type-mismatch
            ret[#ret + 1] = utils.icons.notification[item.kind][item.status]
            ret[#ret + 1] = { string.format("#%d", item.subject.number), "Comment" }
            ret[#ret + 1] = { " " }
            ret[#ret + 1] = { item.repository.full_name, "Function" }
            ret[#ret + 1] = { " " }
            ret[#ret + 1] = { item.subject.title, "Normal" }
            return ret
          end,
          win = {
            input = {
              -- Use the generated and potentially overridden keys
              keys = snacks_config.keys,
            },
          },
          -- Pass the merged actions
          actions = snacks_config.actions,
        }
      end
    end,
  }
end

function M.issue_templates(templates, cb)
  if not templates or #templates == 0 then
    utils.error "No templates found"
    return
  end

  local formatted_templates = {}
  for _, template in ipairs(templates) do
    if template and not vim.tbl_isempty(template) then
      local item = {
        value = template.name,
        display = template.name .. (template.about and (" - " .. template.about) or ""),
        ordinal = template.name .. " " .. (template.about or ""),
        template = template,
      }
      table.insert(formatted_templates, item)
    end
  end

  local preview_fn = function(ctx)
    ctx.preview:reset()

    local item = ctx.item
    if not item or not item.template or not item.template.body then
      ctx.preview:set_lines { "No template body available" }
      return
    end

    local lines = vim.split(item.template.body, "\n")
    ctx.preview:set_lines(lines)
    ctx.preview:highlight { ft = "markdown" }
  end

  local cfg = octo_config.values
  -- Define hardcoded actions (only confirm in this case)
  local hardcoded_actions = {
    confirm = function(_, item)
      if type(cb) == "function" then
        cb(item.template)
      end
    end,
    -- Add other template-specific actions here if needed
  }

  -- Build the keys and merged actions using the helper
  -- Note: Default snacks_picker.mappings likely won't apply here unless we add 'confirm' etc.
  local snacks_config = build_snacks_config(hardcoded_actions, cfg)

  Snacks.picker.pick {
    title = "Issue templates",
    items = formatted_templates,
    format = function(item)
      if type(item) ~= "table" then
        return { { "Invalid item", "Error" } }
      end

      local ret = {}
      ret[#ret + 1] = { item.value or "", "Function" }

      if item.template and item.template.about and item.template.about ~= "" then
        ret[#ret + 1] = { " - ", "Comment" }
        ret[#ret + 1] = { item.template.about, "Normal" }
      end

      return ret
    end,
    preview = preview_fn, -- Use our custom preview function
    win = {
      input = {
        -- Use the generated keys (likely just custom ones + default confirm <cr>)
        keys = snacks_config.keys,
      },
    },
    -- Pass the merged actions (hardcoded + custom)
    actions = snacks_config.actions,
  }
end

function M.search(opts)
  opts = opts or {}
  opts.type = opts.type or "ISSUE"

  if opts.type == "REPOSITORY" then
    M.not_implemented()
    return
  end

  local cfg = octo_config.values
  if type(opts.prompt) == "string" then
    opts.prompt = { opts.prompt }
  end

  local search_results = {}

  local process_results = function(results)
    if #results == 0 then
      return
    end

    for _, item in ipairs(results) do
      if item.__typename == "Issue" then
        item.kind = "issue"
        item.file = utils.get_issue_uri(item.number, item.repository.nameWithOwner)
      elseif item.__typename == "PullRequest" then
        item.kind = "pull_request"
        item.file = utils.get_pull_request_uri(item.number, item.repository.nameWithOwner)
      elseif item.__typename == "Discussion" then
        item.kind = "discussion"
        item.file = utils.get_discussion_uri(item.number, item.repository.nameWithOwner)
      end

      item.text = item.title .. " #" .. item.number .. (item.category and (" " .. item.category.name) or "")
      table.insert(search_results, item)
    end
  end

  for _, val in ipairs(opts.prompt) do
    local output = gh.api.graphql {
      query = queries.search,
      fields = { prompt = val, type = opts.type },
      jq = ".data.search.nodes",
      opts = { mode = "sync" },
    }

    if not utils.is_blank(output) then
      local results = vim.json.decode(output)
      process_results(results)

      if #results == 0 then
        utils.info(string.format("No results found for query: %s", val))
      end
    end
  end

  if #search_results > 0 then
    local max_number = -1
    for _, item in ipairs(search_results) do
      if item.number and item.number > max_number then
        max_number = item.number
      end
    end

    -- Define the hardcoded actions available for *this* picker
    local hardcoded_actions = {
      open_in_browser = function(_, item)
        navigation.open_in_browser(item.kind, item.repository.nameWithOwner, item.number)
      end,
      copy_url = function(_, item)
        utils.copy_url(item.url)
      end,
      -- Add other search-specific actions here if needed
    }

    -- Build the keys and merged actions using the helper
    local snacks_config = build_snacks_config(hardcoded_actions, cfg)

    Snacks.picker.pick {
      title = opts.preview_title or "GitHub Search Results",
      items = search_results,
      format = function(item, _)
        local a = Snacks.picker.util.align
        local ret = {} ---@type snacks.picker.Highlight[]

        ---@diagnostic disable-next-line: assign-type-mismatch
        ret[#ret + 1] = utils.get_icon { kind = item.kind, obj = item }

        ret[#ret + 1] = { " " }

        local issue_id = string.format("#%d", item.number)
        local issue_id_width = #tostring(max_number) + 1

        ret[#ret + 1] = { a(issue_id, issue_id_width), "SnacksPickerGitIssue" }

        ret[#ret + 1] = { " " }

        ret[#ret + 1] = { item.title }

        if item.kind == "discussion" and item.category then
          ret[#ret + 1] = { " [" .. item.category.name .. "]", "SnacksPickerSpecial" }
        end

        return ret
      end,
      win = {
        preview = {
          title = "",
          minimal = true,
        },
        input = {
          -- Use the generated keys
          keys = snacks_config.keys,
        },
      },
      -- Pass the merged actions (hardcoded + custom)
      actions = snacks_config.actions,
    }
  else
    utils.info "No search results found"
  end
end

M.picker = {
  actions = M.not_implemented,
  assigned_labels = M.not_implemented,
  assignees = M.not_implemented,
  changed_files = M.not_implemented,
  commits = M.not_implemented,
  discussions = M.not_implemented,
  gists = M.not_implemented,
  issue_templates = M.issue_templates,
  issues = M.issues,
  labels = M.not_implemented,
  notifications = M.notifications,
  pending_threads = M.not_implemented,
  project_cards = M.not_implemented,
  project_cards_v2 = M.not_implemented,
  project_columns = M.not_implemented,
  project_columns_v2 = M.not_implemented,
  prs = M.pull_requests,
  repos = M.not_implemented,
  workflow_runs = M.not_implemented,
  review_commits = M.not_implemented,
  search = M.search,
  users = M.not_implemented,
  milestones = M.not_implemented,
}

return M
