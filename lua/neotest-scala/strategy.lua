local utils = require("neotest-scala.utils")
local nio = require("nio")

local M = {}

---@param file_path string
---@return table|nil
local function build_test_file_config(file_path)
    if not file_path then
        return nil
    end

    return {
        type = "scala",
        request = "launch",
        name = "Run Test",
        metals = {
            runType = "testFile",
            path = vim.uri_from_fname(file_path),
        },
    }
end

--- Custom strategy that runs commands without a PTY.
--- The default neotest integrated strategy uses pty=true, which causes sbt
--- to hang even with --batch. This strategy uses jobstart without PTY so
--- sbt exits properly after completing tests.
---@async
---@param spec neotest.RunSpec
---@return neotest.Process
local function no_pty_strategy(spec)
    local env, cwd = spec.env, spec.cwd
    local command = spec.command

    local output_path = nio.fn.tempname()
    local finish_future = nio.control.future()
    local result_code = nil

    -- jobstart expects command as a table [prog, arg1, arg2, ...]
    local cmd_table
    if type(command) == "table" then
        cmd_table = command
    else
        cmd_table = vim.split(command, " ")
    end

    local job = nio.fn.jobstart(cmd_table, {
        cwd = cwd,
        pty = false,
        stdout_buffer_size = 2048,
        on_stdout = function(_, data)
            -- Write output to temp file for results parsing
            local f = io.open(output_path, "a")
            if f then
                for _, line in ipairs(data) do
                    f:write(line .. "\n")
                end
                f:close()
            end
        end,
        on_stderr = function(_, data)
            local f = io.open(output_path, "a")
            if f then
                for _, line in ipairs(data) do
                    f:write(line .. "\n")
                end
                f:close()
            end
        end,
        on_exit = function(_, code)
            result_code = code
            finish_future.set()
        end,
    })

    return {
        is_complete = function()
            return result_code ~= nil
        end,
        output = function()
            return output_path
        end,
        stop = function()
            nio.fn.jobstop(job)
        end,
        output_stream = function()
            return function()
                -- Return the full output at once
                local f = io.open(output_path, "r")
                if f then
                    local content = f:read("*a")
                    f:close()
                    return content
                end
                return nil
            end
        end,
        attach = function()
            -- No PTY, can't attach interactively
        end,
        result = function()
            if result_code == nil then
                finish_future.wait()
            end
            return result_code
        end,
    }
end

---@class neotest-scala.StrategyGetConfigOpts
---@field strategy string|nil
---@field tree neotest.Tree

---@param opts neotest-scala.StrategyGetConfigOpts
---@return table|nil
function M.get_config(opts)
    local strategy = opts.strategy
    local tree = opts.tree
    local position = tree:data()

    if strategy == "dap" then
        if position.type == "dir" then
            return nil
        end

        if position.type == "file" then
            return build_test_file_config(position.path)
        end

        if position.type == "namespace" then
            local package_name = utils.get_package_name(position.path) or ""
            return {
                type = "scala",
                request = "launch",
                name = "from_lens",
                metals = {
                    testClass = package_name .. position.name,
                },
            }
        end

        if position.type == "test" then
            return build_test_file_config(position.path)
        end

        return nil
    end

    -- For non-DAP runs, return the no-PTY strategy to avoid sbt hanging
    -- with the default integrated strategy's pty=true
    return no_pty_strategy
end

return M
