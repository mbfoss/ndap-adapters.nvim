-- Directories that may hold the bashdb library, in order; the first one that
-- holds a `bashdb` script wins. Put your own directory first to pin it. "$VAR"
-- and "~" expand anywhere in an entry, as they do in `vim.fs.normalize`; an
-- entry naming an unset or empty variable is skipped. Mason is only one of the
-- entries and not required: the extension ships the same `bashdb_dir` inside its
-- .vsix, which $BASH_DEBUG_ADAPTER can point at, and a system bashdb install is
-- named through $BASHDB_HOME.
local bashdb_lib_dirs = {
    "$BASHDB_HOME",
    "$BASH_DEBUG_ADAPTER/extension/bashdb_dir",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter", "extension", "bashdb_dir"),
}

-- Those same directories as the driver script inside each, so `resolve_path` is
-- handed the file it actually tests.
local bashdb_scripts = vim.tbl_map(function(dir) return vim.fs.joinpath(dir, "bashdb") end,
    bashdb_lib_dirs)

-- Where to look for the adapter, in order; the first executable wins. Put your
-- own path first to pin it. A bare name (no separator) is looked up on $PATH,
-- which is where an npm or distro install is picked up from; mason's shim is on
-- $PATH only when mason.nvim was set up to put it there, so the binary inside
-- the package is listed too; mason itself is not required.
local bash_debug_bins = {
    "bash-debug-adapter",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "bin", "bash-debug-adapter"),
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter", "bash-debug-adapter"),
}

-- External programs the adapter shells out to; each is looked up on $PATH unless
-- given as an absolute path.
local bash_tools = {
    bash   = "bash",
    cat    = "cat",
    mkfifo = "mkfifo",
    pkill  = "pkill",
}

---The driver script for the body's `pathBashdb`/`pathBashdbLib`: the one inside a
---resolved library directory, or a `bashdb` on $PATH when only a system install is
---around, whose library sits beside the driver or under the install prefix.
---@return string? script, string? lib_dir, string? err
local function _bashdb()
    local shared = require("ndap.shared")
    local script, tried = shared.resolve_path(bashdb_scripts,
        function(path) return vim.fn.filereadable(path) == 1 end)
    if script then return script, vim.fs.dirname(script) end

    -- `--library` overrides bashdb's own search, so an install whose library is
    -- not one of these would be worse off for being handed a guessed directory.
    local exe = vim.fn.exepath("bashdb")
    if exe ~= "" then
        local bin = vim.fs.dirname(vim.fn.resolve(exe))
        for _, dir in ipairs({ bin, vim.fs.joinpath(vim.fs.dirname(bin), "share", "bashdb") }) do
            if vim.fn.filereadable(vim.fs.joinpath(dir, "dbg-main.sh")) == 1 then
                return exe, dir
            end
        end
        return nil, nil, "found " .. exe .. " but not its library directory; " ..
            "set $BASHDB_HOME to the directory holding dbg-main.sh"
    end

    return nil, nil, "bashdb not found (install bashdb, set $BASHDB_HOME, or point " ..
        "$BASH_DEBUG_ADAPTER at the extension's bashdb_dir); tried " ..
        table.concat(tried, ", ") .. ", bashdb"
end

---@type ndap.AdapterDef
return {
    -- Nothing to spawn, since the adapter speaks DAP over stdio, but a missing
    -- binary fails the session with no legible reason, so the lookup happens
    -- here, where a plain error string reaches the user, and the config is
    -- pointed at what it finds.
    setup    = function(config, _, callback)
        local shared = require("ndap.shared")
        local exe, tried = shared.resolve_path(bash_debug_bins, shared.is_executable)
        if not exe then
            return callback("bash-debug-adapter not found (install it from npm, a distro package, or mason); tried " ..
                table.concat(tried, ", "))
        end
        config.command = exe
        callback()
    end,
    modes = {
        script = {
            description = "debug a bash script",
            request = "launch",
            inputs = {
                script        = { type = "string", completion = "file", description = "bash script to debug" },
                args          = { type = "list", description = "arguments passed to the script" },
                args_string   = { type = "string", description = "arguments passed as one command line string, appended after args" },
                cwd           = { type = "string", completion = "dir", description = "working directory" },
                env           = { type = "map", description = "environment variables" },
                terminal_kind = { type = "string", completion = { "integrated", "external", "debugConsole" }, description = "where the debuggee's stdio goes (default integrated)" },
                path_bash     = { type = "string", completion = "file", description = "bash to run the debuggee with (default bash on $PATH)" },
                path_cat      = { type = "string", completion = "file", description = "cat the adapter uses (default cat on $PATH)" },
                path_mkfifo   = { type = "string", completion = "file", description = "mkfifo the adapter uses (default mkfifo on $PATH)" },
                path_pkill    = { type = "string", completion = "file", description = "pkill the adapter uses (default pkill on $PATH)" },
            },
            -- The body names the driver script and its library, and `build` runs
            -- before `setup`, so this lookup, unlike every other, cannot wait
            -- until then. A missing bashdb is an abort, not a body naming a
            -- script that is not there.
            build = function(parameters)
                local shared = require("ndap.shared")
                local script, lib_dir, err = _bashdb()
                if not script then return nil, err end
                return {
                    type          = "bashdb",
                    name          = "bash-debug",
                    program       = shared.normalize_path(parameters.script),
                    args          = parameters.args or {}, -- args is required
                    argsString    = parameters.args_string or "",  -- args is required
                    -- bashdb requires a cwd, so an unset input falls back to nvim's.
                    cwd           = shared.normalize_path(parameters.cwd) or vim.fn.getcwd(),
                    -- The adapter calls Object.keys on this, so an unset map must
                    -- still arrive as an object; the exports layer over its env.
                    env           = parameters.env or vim.empty_dict(),
                    pathBash      = shared.normalize_path(parameters.path_bash) or bash_tools.bash,
                    pathBashdb    = script,
                    pathBashdbLib = lib_dir,
                    pathCat       = shared.normalize_path(parameters.path_cat) or bash_tools.cat,
                    pathMkfifo    = shared.normalize_path(parameters.path_mkfifo) or bash_tools.mkfifo,
                    pathPkill     = shared.normalize_path(parameters.path_pkill) or bash_tools.pkill,
                    terminalKind  = parameters.terminal_kind or "integrated",
                }
            end,
        },
    },
}
