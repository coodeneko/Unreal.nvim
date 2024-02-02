local M = {}

local async = require("plenary.async")
local p = require("plenary.path")
local job = require("plenary.job")
local scan = require("plenary.scandir")

local kConfigFileName = "UnrealNvim.json"
local kCurrentVersion = "0.0.3"
local kPluginTitle = "Unreal.nvim"
local kUnrealBuildTool = "Engine\\Build\\BatchFiles\\Build.bat"
local kUnrealEditor = "Engine\\Binaries\\Win64\\UnrealEditor.exe"

M.current_config = nil
M.current_buffer = nil
M.current_window = nil

local P = function(...)
    print(vim.inspect(...))
end

local default_config = function()
    return {
        version = kCurrentVersion,
        _comment = "don't forget to escape backslashes in EnginePath",
        EngineDir = vim.loop.cwd(),
        Targets = {},
    }
end

local read_file = function(path)
    local err, fd, stat, data

    err, fd = async.uv.fs_open(path, "r", 0)
    assert(not err, err)
    err, stat = async.uv.fs_fstat(fd)
    assert(not err, err)
    err, data = async.uv.fs_read(fd, stat.size, 0)
    assert(not err, err)
    err = async.uv.fs_close(fd)
    assert(not err, err)

    return data
end
local write_file = function(path, data)
    local err, fd

    err, fd = async.uv.fs_open(path, "w", 438)
    assert(not err, err)
    err = async.uv.fs_write(fd, data)
    assert(not err, err)
    err = async.uv.fs_close(fd)
    assert(not err, err)
end

local folders_to_search = function(uprojectdirs)
    local folders = {}

    local err, fd = async.uv.fs_open(uprojectdirs, "r", 0)
    if err then
        return {"."}
    end
    err = async.uv.fs_close(fd)
    assert(not err, err)

    local data = read_file(uprojectdirs)

    for line in data:gmatch("([^\r\n]*)\r?\n?") do
       if line == nil or line == "" then goto continue end
       if string.sub(line, 1, 1) == ";" then goto continue end
       table.insert(folders, p:new(line):normalize(vim.loop.cwd()))
       ::continue::
    end

    return folders
end

local generate_target = function(path, name, with_editor, configuration)
    return {
        ProjectPath = path,
        TargetName = name .. (with_editor and "Editor" or ""),
        Configuration = configuration,
        withEditor = with_editor,
        UbtExtraFlags = "",
        PlatformName = "Win64",
    }
end

M.initialize_config = function(opts)
        opts = opts or {}
        opts.uprojectdirs = opts.uprojectdirs or "Default.uprojectdirs"
        opts.silent = opts.silent or true
        local cwd = vim.loop.cwd().."/"
        local dirs = folders_to_search(opts.uprojectdirs)

        local projects_files = scan.scan_dir(dirs, { depth = 2, search_pattern = ".*%.uproject$", silent=opts.silent})
        local projects = {}
        for _, project_path in ipairs(projects_files) do
            local project = {}
            project.project = vim.fs.basename(project_path)
            project.path = vim.fs.normalize(cwd..project_path)
            project.dir = vim.fs.dirname(project.path)
            project.engine_parent = vim.fs.normalize(cwd)
            local targets = scan.scan_dir(project.dir.."/Source", {depth = 1, search_pattern = ".*%.Target%.cs$", silent=opts.silent})
            for j, target in ipairs(targets) do
                targets[j] = string.match(vim.fs.basename(target), "(.*)%.Target%.cs")
            end
            project.targets = targets
            if next(project.targets) ~= nil then
                table.insert(projects, project)
            end
        end
        M.current_config = projects
end

M.generate_config = function(opts)
    async.run(function()
        opts = opts or {}
        opts.uprojectdirs = opts.uprojectdirs or "Default.uprojectdirs"
        local dirs = folders_to_search(opts.uprojectdirs)

        local projects_files = scan.scan_dir(dirs, {
            depth = 2,
            search_pattern = ".*%.uproject$",})
        local projects = {}
        for _, v in ipairs(projects_files) do
            v = vim.fs.normalize(v)
            local path = p:new(v)
            if not path:is_absolute() then path = p:new(vim.loop.cwd(), v) end
            path = string.gsub(vim.fs.normalize(path:absolute()), "%/%.%/", "/")
            local project_data = read_file(path)
            projects[path] = project_data
        end
        local tx, rx = async.control.channel.oneshot()
        local function read_json()
            local output = default_config()
            for k, v in pairs(projects) do
                local project_data = vim.fn.json_decode(v)
                if project_data.Modules == nil then goto continue end
                table.insert(output.Targets, generate_target(k, project_data.Modules[1].Name, true, "Development"))
                ::continue::
            end
            tx(vim.fn.json_encode(output))
        end
        async.util.scheduler(read_json)
        local output = rx()
        write_file(kConfigFileName, output)
    end)
end

M.load_config = function()
    async.run(function()
        if not p:new(kConfigFileName):exists() then
            vim.notify("No config file", vim.log.levels.ERROR, { title = kPluginTitle })
            return
        end

        local json = read_file(kConfigFileName)
        async.util.scheduler(function()
            M.current_config = vim.fn.json_decode(json)
            vim.notify("Config loaded", vim.log.levels.TRACE, { title = kPluginTitle })
        end)
    end)
end

-- Build
-- GenerateClangDatabase

M.unreal_build_tool = function(module, mode, opts)
    async.run(function()
        opts = opts or {}
        if M.current_config == nil then
            M.initialize_config()
        end

        local ubt = vim.fs.normalize(M.current_config[1].engine_parent.."/"..kUnrealBuildTool)
        local target = "Win64"
        local level = "Development"
        local args = {module, target, level, "-mode="..mode, "-waitmutex", "-game", "-progress"}

        async.util.scheduler(function()
            vim.api.nvim_win_call(0, function()
                if M.current_window == nil then
                    vim.cmd("below new")
                    vim.cmd("wincmd J")
                    vim.cmd("res 10 wincmd _")
                    M.current_window = vim.api.nvim_get_current_win()
                end
                local win = M.current_window
                if M.current_buffer == nil then
                    M.current_buffer = vim.api.nvim_create_buf(false, true)
                end
                local buf = M.current_buffer
                vim.api.nvim_win_set_buf(win, buf)

                local chan = vim.api.nvim_open_term(buf, {})
                job:new({
                    command = ubt,
                    args = args,
                    on_stdout = vim.schedule_wrap(function(_, data, _)
                        vim.api.nvim_chan_send(chan, data .. '\r\n')
                        local line = vim.fn.getbufinfo(buf)
                        line = line[1]['linecount']
                        vim.api.nvim_win_set_cursor(win, {line, 0})
                    end),
                }):start()
            end)
        end)
    end)
end

local popup = require("plenary.popup")

M.select_job = function(opts)
    async.run(function()
        if M.current_config == nil then
            M.initialize_config(opts)
        end

        local tasks = {}
        for _, project in ipairs(M.current_config) do
            for _, target in ipairs(project.targets) do
                for _, mode in ipairs({"Build", "GenerateClangDatabase"}) do
                    table.insert(tasks, project.project .. " - " .. target .. " - " .. mode)
                end
            end
        end
        table.insert(tasks, "Quit")


        async.util.scheduler(function()
        local height = 20
        local width = 30
        local borderchars = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" }

        local _ = vim.ui.select(tasks, {
            title = "MyProjects",
            highlight = "MyProjectWindow",
            line = math.floor(((vim.o.lines - height) / 2) - 1),
            col = math.floor((vim.o.columns - width) / 2),
            minwidth = width,
            minheight = height,
            borderchars = borderchars,
        },
            function(sel)
                if sel == "Quit" then return end

                local _, target, mode = string.match(sel, "(.*) %- (.*) %- (.*)")
                --P({project, target, mode})
                M.unreal_build_tool(target, mode)
            end
        )
    end)
        --local bufnr = vim.api.nvim_win_get_buf(Win_id)
    end)
end

M.run_project = function(_)
    async.run(function()
        if M.current_config == nil then
            M.initialize_config()
        end

    local projects = {}
    for _, project in ipairs(M.current_config) do
        table.insert(projects, project.path)
    end
    table.insert(projects, "Quit")

    async.util.scheduler(function()
        local height = 20
        local width = 30
        local borderchars = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" }

        local _ = popup.create(projects, {
            title = "MyProjects",
            highlight = "MyProjectWindow",
            line = math.floor(((vim.o.lines - height) / 2) - 1),
            col = math.floor((vim.o.columns - width) / 2),
            minwidth = width,
            minheight = height,
            borderchars = borderchars,
            callback = function(_, sel)
                if sel == "Quit" then return end

        local ubt = vim.fs.normalize(M.current_config[1].engine_parent.."/"..kUnrealEditor)
        local args = {sel, "-skipcompile"}

        async.util.scheduler(function()
            vim.api.nvim_win_call(0, function()
                if M.current_window == nil then
                    vim.cmd("below new")
                    vim.cmd("wincmd J")
                    M.current_window = vim.api.nvim_get_current_win()
                end
                local win = M.current_window
                if M.current_buffer == nil then
                    M.current_buffer = vim.api.nvim_create_buf(false, true)
                end
                local buf = M.current_buffer
                vim.api.nvim_win_set_buf(win, buf)

                local chan = vim.api.nvim_open_term(buf, {})
                job:new({
                    command = ubt,
                    args = args,
                    on_stdout = vim.schedule_wrap(function(_, data, _)
                        vim.api.nvim_chan_send(chan, data .. '\r\n')
                        local line = vim.fn.getbufinfo(buf)
                        line = line[1]['linecount']
                        vim.api.nvim_win_set_cursor(win, {line, 0})
                    end),
                }):start()
            end)
        end)
            end,
        })

    end)
    end)
end

M.setup = function(opts)
    opts = opts or {}
    kConfigFileName = opts.config_filename or "UnrealNvim.json"
end

return M;

