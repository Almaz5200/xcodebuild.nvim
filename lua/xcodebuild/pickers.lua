local xcode = require("xcodebuild.xcode")
local config = require("xcodebuild.config")
local util = require("xcodebuild.util")

local telescopePickers = require("telescope.pickers")
local telescopeFinders = require("telescope.finders")
local telescopeConfig = require("telescope.config").values
local telescopeActions = require("telescope.actions")
local telescopeState = require("telescope.actions.state")

local M = {}

local active_picker = nil
local anim_timer = nil
local current_frame = 1
local spinner_anim_frames = {
	"[      ]",
	"[ .    ]",
	"[ ..   ]",
	"[ ...  ]",
	"[  ... ]",
	"[   .. ]",
	"[    . ]",
}

local function update_telescope_spinner()
	if active_picker then
		current_frame = current_frame >= #spinner_anim_frames and 1 or current_frame + 1
		active_picker:change_prompt_prefix(spinner_anim_frames[current_frame] .. " ", "TelescopePromptPrefix")
		vim.cmd("echo '" .. spinner_anim_frames[current_frame] .. "'")
	end
end

local function start_telescope_spinner()
	if not anim_timer then
		anim_timer = vim.fn.timer_start(80, update_telescope_spinner, { ["repeat"] = -1 })
	end
end

local function stop_telescope_spinner()
	if anim_timer then
		vim.fn.timer_stop(anim_timer)
		anim_timer = nil
		vim.cmd("echo ''")
	end
end

local function update_results(results)
	stop_telescope_spinner()

	if active_picker then
		active_picker:refresh(
			telescopeFinders.new_table({
				results = results,
			}),
			{
				new_prefix = telescopeConfig.prompt_prefix,
			}
		)
	end
end

function M.show(title, items, callback, opts)
	active_picker = telescopePickers.new(require("telescope.themes").get_dropdown({}), {
		prompt_title = title,
		finder = telescopeFinders.new_table({
			results = items,
		}),
		sorter = telescopeConfig.generic_sorter(),
		attach_mappings = function(prompt_bufnr, _)
			telescopeActions.select_default:replace(function()
				if opts and opts.close_on_select then
					telescopeActions.close(prompt_bufnr)
				end

				local selection = telescopeState.get_selected_entry()
				if callback and selection then
					callback(selection[1], selection.index)
				end
			end)
			return true
		end,
	})

	active_picker:find()
end

function M.select_project(callback, opts)
	local files = util.shell(
		"find '"
			.. vim.fn.getcwd()
			.. "' \\( -iname '*.xcodeproj' -o -iname '*.xcworkspace' \\) -not -path '*/.*' -not -path '*xcodeproj/project.xcworkspace'"
	)
	local sanitizedFiles = {}

	for _, file in ipairs(files) do
		if util.trim(file) ~= "" then
			table.insert(sanitizedFiles, {
				filepath = file,
				name = string.match(file, ".*%/([^/]*)$"),
			})
		end
	end

	local filenames = util.select(sanitizedFiles, function(table)
		return table.name
	end)

	if not next(filenames) then
		vim.notify("Could not a detect project file")
		return
	end

	M.show("Select Project/Workspace", filenames, function(_, index)
		local projectFile = sanitizedFiles[index].filepath
		local isWorkspace = util.hasSuffix(projectFile, "xcworkspace")

		config.settings().projectFile = projectFile
		config.settings().projectCommand = (isWorkspace and "-workspace '" or "-project '") .. projectFile .. "'"
		config.save_settings()

		if callback then
			callback(projectFile)
		end
	end, opts)
end

function M.select_scheme(callback, opts)
	local projectCommand = config.settings().projectCommand
	start_telescope_spinner()
	M.show("Select Scheme", {}, function(value, _)
		config.settings().scheme = value
		config.save_settings()

		if callback then
			callback()
		end
	end, opts)

	return xcode.get_schemes(projectCommand, update_results)
end

function M.select_testplan(callback, opts)
	local projectCommand = config.settings().projectCommand
	local scheme = config.settings().scheme

	start_telescope_spinner()
	M.show("Select Test Plan", {}, function(value, _)
		config.settings().testPlan = value
		config.save_settings()

		if callback then
			callback(value)
		end
	end, opts)

	return xcode.get_testplans(projectCommand, scheme, update_results)
end

function M.select_destination(callback, opts)
	local projectCommand = config.settings().projectCommand
	local scheme = config.settings().scheme
	local results = {}

	start_telescope_spinner()
	M.show("Select Device", {}, function(_, index)
		if index <= 0 then
			return
		end

		config.settings().destination = results[index].id
		config.save_settings()

		if callback then
			callback(results[index])
		end
	end, opts)

	return xcode.get_destinations(projectCommand, scheme, function(destinations)
		local filtered = util.filter(destinations, function(table)
			return table.id ~= nil
				and table.platform ~= "iOS"
				and (not table.name or not string.find(table.name, "^Any"))
		end)

		local destinationsName = util.select(filtered, function(table)
			local name = table.name or ""
			if table.platform and table.platform ~= "iOS Simulator" then
				name = util.trim(name .. " " .. table.platform)
			end
			if table.platform == "macOS" and table.arch then
				name = name .. " (" .. table.arch .. ")"
			end
			if table.os then
				name = name .. " (" .. table.os .. ")"
			end
			if table.variant then
				name = name .. " (" .. table.variant .. ")"
			end
			if table.error then
				name = name .. " [error]"
			end
			return name
		end)

		results = filtered
		update_results(destinationsName)
	end)
end

function M.show_all_actions()
	local actions = require("xcodebuild.actions")
	local actionsNames = {
		"Build Project",
		"Build & Run Project",
		"Run Without Building",
		"Stop Running Action",

		"Test Project",
		"Test Class",
		"Test Function",
		"Test Selected Functions",
		"Test Failed Tests",

		"Select Project File",
		"Select Scheme",
		"Select Device",
		"Select Test Plan",
		"Show Configuration Wizard",

		"Toggle Logs",
		"Show Logs",
		"Close Logs",
	}
	local actionsPointers = {
		actions.build,
		actions.build_and_run,
		actions.run,
		actions.cancel,

		actions.run_tests,
		actions.run_class_tests,
		actions.run_func_test,
		actions.run_selected_tests,
		actions.run_failing_tests,

		actions.select_project,
		actions.select_scheme,
		actions.select_device,
		actions.select_testplan,
		actions.configure_project,

		actions.toggle_logs,
		actions.show_logs,
		actions.close_logs,
	}
	M.show("Xcodebuild Actions", actionsNames, function(_, index)
		if index > 9 then
			actionsPointers[index]()
		else
			vim.defer_fn(actionsPointers[index], 100)
		end
	end, { close_on_select = true })
end

return M