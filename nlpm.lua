---@class PackageDependency
---@field name string package name as it will be used in file gen
---@field repo string git repo
---@field version? string git hash(#) or tag(v), defaults to "#HEAD"

---@class Package
---@field dependencies? PackageDependency[] List of package dependencies
---@field scripts? table<string, string> scripts that can be called with `nlpm script`

local lfs = require("lfs")

local fs = require("nelua.utils.fs")
local platform = require("nelua.utils.platform")

local NLPM_PACKAGE_NAME <const> = "nlpm_package"
local NLPM_PACKAGE_FILE <const> = NLPM_PACKAGE_NAME .. ".lua"
local NLPM_PACKAGE_VARIABLE <const> = "NLPM_PACKAGES_PATH"
local ROOT_DIR <const> = lfs.currentdir()
local NLPM_PACKAGES = "nlpm_packages"
local GITIGNORE <const> = ".gitignore"

local DEFAULT_NELUA_PATHS <const> = {
  "./?.nelua",
  "./?/init.nelua",
  "/usr/local/lib/nelua/lib/?.nelua",
  "/usr/local/lib/nelua/lib/?/init.nelua",
}

local log = false

---@param ok any
---@param err string?
local function mild_assert(ok, err)
  if not ok then
    local info = debug.getinfo(2)
    local error_msg = err or ("Assertion failed: %s:%s"):format(info.source, info.currentline)
    io.stderr:write("ERROR: " .. error_msg .. "\n")
    os.exit(1)
  end
end

---@param cmd_to_run string
---@param cmd_to_log string?
---@return boolean? success
local function run_command(cmd_to_run, cmd_to_log)
  local result
  if log then
    print("RUNNING: " .. (cmd_to_log and cmd_to_log or cmd_to_run) .. "\n")
    result = os.execute(cmd_to_run)
  else
    result = os.execute(platform.is_windows and cmd_to_run .. " > NUL 2>&1" or cmd_to_run .. " > /dev/null 2>&1")
  end
  return result
end

---@param path string
local function remove_file_or_dir(path)
  if not (fs.isfile(path) or fs.isdir(path)) then
    return
  end

  local attr = lfs.attributes(path)
  if not attr then
    return
  end

  if attr.mode == "directory" then
    for file in lfs.dir(path) do
      if file ~= "." and file ~= ".." then
        local sub_path = path .. "/" .. file
        remove_file_or_dir(sub_path)
      end
    end
    lfs.rmdir(path)
  else
    os.remove(path)
  end
end

---@param package_dir string
---@return string[]
---@return string[]
local function get_package_paths(package_dir)
  local nelua_package_paths = {}
  local lua_package_paths = {}
  if fs.isdir(package_dir) then
    for package in lfs.dir(package_dir) do
      if package ~= "." and package ~= ".." then
        local abs_path = fs.abspath(package_dir .. "/" .. package)
        table.insert(nelua_package_paths, abs_path .. "/?.nelua")
        table.insert(nelua_package_paths, abs_path .. "/?/init.nelua")
        table.insert(lua_package_paths, abs_path .. "/?.lua")
        table.insert(lua_package_paths, abs_path .. "/?/init.lua")
      end
    end
  end
  return nelua_package_paths, lua_package_paths
end

---@param dependency PackageDependency
---@return string dep_name
---@return string dep_type
---@return string dep_version
local function gen_dep_name(dependency)
  local dep_type = "#"
  local dep_version = "HEAD"

  if dependency.version and dependency.version ~= "" then
    local parsed_type, parsed_version = dependency.version:match("([%#v])(.+)")
    mild_assert(
      parsed_type and parsed_version,
      ("Invalid version format '%s' for dependency '%s'. Use #<hash> or v<tag>"):format(
        dependency.version,
        dependency.name
      )
    )
    dep_type = parsed_type
    dep_version = parsed_version
  end

  return ("%s@%s%s"):format(dependency.name, dep_type, dep_version), dep_type, dep_version
end

---@param package_dir string
---@param dependency PackageDependency
---@param depth? boolean
local function install(package_dir, dependency, depth)
  local original_dir = lfs.currentdir()

  local ok, err = lfs.chdir(package_dir)
  mild_assert(ok, ("Failed to change to package directory: %s"):format(err or "unknown error"))

  local dep_name, dep_type, dep_version = gen_dep_name(dependency)
  local abs_dep_path = fs.abspath(dep_name)

  -- Clean up existing HEAD installations on fresh installs
  if dep_version == "HEAD" and fs.isdir(dep_name) and not depth then
    remove_file_or_dir(dep_name)
  end

  if not fs.isdir(dep_name) then
    print(('Installing package "%s"...'):format(dep_name))

    -- Clone the repository
    local clone_success = run_command(("git clone --depth 1 %s %s"):format(dependency.repo, dep_name))
    mild_assert(
      clone_success,
      ("Failed to clone repository for '%s'. Please verify the repository URL."):format(dep_name)
    )

    ok, err = lfs.chdir(dep_name)
    mild_assert(ok, ("Failed to enter cloned directory: %s"):format(err or "unknown error"))

    if fs.isfile(NLPM_PACKAGE_FILE) then
      local current_dir = lfs.currentdir()
      lfs.chdir(ROOT_DIR)

      local sub_require_path = (package_dir):sub(#ROOT_DIR + 2) .. "." .. dep_name .. "." .. NLPM_PACKAGE_NAME
      local sub_package_ok, sub_package = pcall(require, sub_require_path)

      if sub_package_ok and sub_package.dependencies then
        for _, dep in ipairs(sub_package.dependencies) do
          install(package_dir, dep, true)
        end
      end

      lfs.chdir(current_dir)
    end

    if dep_version ~= "HEAD" then
      local is_tag = dep_type == "v"
      local fetch_target = is_tag and ("tag %s%s"):format(dep_type, dep_version) or dep_version
      local checkout_target = is_tag and ("tags/%s%s"):format(dep_type, dep_version) or dep_version

      local fetch_success = run_command(("git fetch origin %s"):format(fetch_target))
      if not fetch_success then
        remove_file_or_dir(abs_dep_path)
        mild_assert(
          false,
          ("Failed to fetch %s for '%s'. Please verify the version exists."):format(
            is_tag and "tag" or "commit",
            dep_name
          )
        )
      end

      local checkout_success = run_command(("git checkout %s"):format(checkout_target))
      if not checkout_success then
        remove_file_or_dir(abs_dep_path)
        mild_assert(
          false,
          ("Failed to checkout %s for '%s'. Please verify the version exists."):format(
            is_tag and "tag" or "commit",
            dep_name
          )
        )
      end
    end

    remove_file_or_dir(".git")

    lfs.chdir(package_dir)
  elseif dep_version ~= "HEAD" then
    print(('Skipping package "%s", already exists'):format(dep_name))
  end

  lfs.chdir(original_dir)
end

---@param package_dir string
---@param package Package
local function clean(package_dir, package)
  print("Cleaning up unmarked packages...")

  if not package.dependencies then
    return
  end

  --- Collect all dependency names
  ---@param deps PackageDependency[]
  ---@param current_package_dir string
  ---@param names {string: boolean}
  local function collect_dependencies(deps, current_package_dir, names)
    for _, dep in ipairs(deps) do
      local name = gen_dep_name(dep)
      names[name] = true

      -- Check for sub-dependencies
      local dep_path = current_package_dir .. "/" .. name
      if fs.isdir(dep_path) and fs.isfile(dep_path .. "/" .. NLPM_PACKAGE_FILE) then
        local original_dir = lfs.currentdir()
        lfs.chdir(ROOT_DIR)

        local sub_require_path = (current_package_dir):sub(#ROOT_DIR + 2) .. "." .. name .. "." .. NLPM_PACKAGE_NAME
        ---@type boolean, Package
        local sub_package_ok, sub_package = pcall(require, sub_require_path)

        if sub_package_ok and sub_package.dependencies then
          collect_dependencies(sub_package.dependencies, current_package_dir, names)
        end

        lfs.chdir(original_dir)
      end
    end
  end

  local dependency_names = {}
  collect_dependencies(package.dependencies, package_dir, dependency_names)

  -- Remove unmarked packages
  local ok, err = lfs.chdir(package_dir)
  mild_assert(ok, err)

  for path in lfs.dir(".") do
    if path ~= "." and path ~= ".." and not dependency_names[path] then
      local abs_path = fs.abspath(path)
      print("Removing " .. abs_path)
      remove_file_or_dir(abs_path)
    end
  end
end

---@param packages_dir string
---@return string
---@return string
local function make_nlpm_path(packages_dir)
  local nelua_package_paths, lua_package_paths = get_package_paths(packages_dir)
  local all_nelua_paths = {}

  for _, path in ipairs(DEFAULT_NELUA_PATHS) do
    table.insert(all_nelua_paths, path)
  end

  for _, path in ipairs(nelua_package_paths) do
    table.insert(all_nelua_paths, path)
  end

  local nelua_path = table.concat(all_nelua_paths, ";")
  local lua_path = table.concat(lua_package_paths, platform.luapath_separator)
  return nelua_path, lua_path
end

---@param packages_dir string
---@param script_command string
local function run_with_nelua_path(packages_dir, script_command)
  local nelua_path, lua_path = make_nlpm_path(packages_dir)
  local env_command = ("LUA_PATH='%s;$LUA_PATH' NELUA_PATH='%s;$NELUA_PATH' %s"):format(
    lua_path,
    nelua_path,
    script_command
  )

  log = true
  local success = run_command(env_command, script_command)
  if not success then
    os.exit(1)
  end
end

local function create_default_package_file()
  if fs.isfile(NLPM_PACKAGE_FILE) then
    print(("Package file '%s' already exists. Skipping step"):format(NLPM_PACKAGE_FILE))
    return
  end

  local content = [[
---@class PackageDependency
---@field name string package name as it will be used in file gen
---@field repo string git repo
---@field version? string git hash(#) or tag(v), defaults to "#HEAD"

---@class Package
---@field dependencies? PackageDependency[] List of package dependencies
---@field scripts? table<string, string> scripts that can be called with `nlpm script`

---@type Package
return {
  dependencies = {},
  scripts = {}
}]]

  local file, err = io.open(NLPM_PACKAGE_FILE, "w")
  mild_assert(file, ("Failed to create %s: %s"):format(NLPM_PACKAGE_FILE, err or "unknown error"))

  ---@diagnostic disable-next-line: need-check-nil
  local written, write_err = file:write(content)
  mild_assert(written, ("Failed to write to %s: %s"):format(NLPM_PACKAGE_FILE, write_err or "unknown error"))

  ---@diagnostic disable-next-line: need-check-nil
  file:close()
  print(NLPM_PACKAGE_FILE .. " successfully created")
end

local function update_gitignore()
  if fs.isfile(GITIGNORE) then
    local file, err = io.open(GITIGNORE, "r")
    mild_assert(file, err)

    ---@diagnostic disable-next-line: need-check-nil
    for line in file:lines() do
      if line:match("%s*(.+)%s*") == NLPM_PACKAGES then
        print("File '" .. GITIGNORE .. "' already exists with ignore rule. Skipping step")
        return -- Already in gitignore
      end
    end
    ---@diagnostic disable-next-line: need-check-nil
    file:close()

    file, err = io.open(GITIGNORE, "a")
    mild_assert(file, err)

    ---@diagnostic disable-next-line: need-check-nil
    local written, write_err = file:write((platform.is_windows and "\r\n" or "\n") .. NLPM_PACKAGES)
    mild_assert(written, write_err)

    ---@diagnostic disable-next-line: need-check-nil
    file:close()
    print("Appended '" .. NLPM_PACKAGES .. "' to .gitignore")
  else
    local file, err = io.open(GITIGNORE, "w")
    mild_assert(file, err)

    ---@diagnostic disable-next-line: need-check-nil
    local written, write_err = file:write(NLPM_PACKAGES)
    mild_assert(written, write_err)

    ---@diagnostic disable-next-line: need-check-nil
    file:close()
    print("Created .gitignore file")
  end
end

local function help()
  print(
    ([[
Usage: nlpm [-h] [--print-nlpm-path] [--log] <command> ...

Arguments:
  runargs                Arguments passed to the run command
                         Use '--' to avoid conflicts with regular commands and options
Options:
   -h, --help            Show this help message and exit
   --print-nlpm-path     Print the nlpm path set for 'NELUA_PATH' and 'LUA_PATH'
   --log                 Enable command logging 

Commands:
   install               Install all dependencies from '%s'
   clean                 Remove packages not listed in '%s'
   script <name>         Run a script from '%s' with the nlpm 'NELUA_PATH' and 'LUA_PATH'
   run [--] <runargs>    Run shell commands with the nlpm 'NELUA_PATH' and 'LUA_PATH'
   new                   Create a new '%s' in the current directory
   nuke                  Delete the packages directory

Environment Variables:
   %s    Directory for package installation (default: ./%s)]]):format(
      NLPM_PACKAGE_FILE,
      NLPM_PACKAGE_FILE,
      NLPM_PACKAGE_FILE,
      NLPM_PACKAGE_NAME,
      NLPM_PACKAGE_VARIABLE,
      NLPM_PACKAGES
    )
  )
end

local commands = {}

---@param packages_dir string
function commands.install(packages_dir)
  mild_assert(
    fs.isfile(NLPM_PACKAGE_FILE),
    ("Package file '%s' not found. Run 'nlpm new' to create one."):format(NLPM_PACKAGE_FILE)
  )

  local package_ok, package = pcall(require, NLPM_PACKAGE_NAME)
  mild_assert(package_ok, ("Failed to load package file: %s"):format(package or "unknown error"))
  mild_assert(package.dependencies, "Package file must contain a 'dependencies' field")

  if not fs.isdir(packages_dir) then
    print("Creating packages directory: " .. packages_dir)
    local ok, err = lfs.mkdir(packages_dir)
    mild_assert(ok, ("Failed to create packages directory: %s"):format(err or "unknown error"))
  end

  print("Installing packages...")
  for _, dependency in ipairs(package.dependencies) do
    install(packages_dir, dependency, false)
  end
  print("Installation complete")

  clean(packages_dir, package)
  print("Cleanup complete")
end

---@param packages_dir string
---@param script_name string
function commands.script(packages_dir, script_name)
  mild_assert(script_name, "Script name is required")
  mild_assert(fs.isfile(NLPM_PACKAGE_FILE), ("Package file '%s' not found"):format(NLPM_PACKAGE_FILE))

  local package_ok, package = pcall(require, NLPM_PACKAGE_NAME)
  mild_assert(package_ok, ("Failed to load package file: %s"):format(package or "unknown error"))
  mild_assert(package.scripts, "Package file must contain a 'scripts' field")

  local script = package.scripts[script_name]
  mild_assert(script, ("Script '%s' not found in package file"):format(script_name))

  print("SCRIPT: " .. script_name)
  run_with_nelua_path(packages_dir, script)
end

---@param packages_dir string
---@param args string[]
---@param start_index integer
function commands.run(packages_dir, args, start_index)
  local command = table.concat(args, " ", start_index)
  mild_assert(command ~= "", "Command is required")

  run_with_nelua_path(packages_dir, command)
end

---@param packages_dir string
function commands.clean(packages_dir)
  mild_assert(fs.isfile(NLPM_PACKAGE_FILE), ("Package file '%s' not found"):format(NLPM_PACKAGE_FILE))

  local package_ok, package = pcall(require, NLPM_PACKAGE_NAME)
  mild_assert(package_ok, ("Failed to load package file: %s"):format(package or "unknown error"))

  clean(packages_dir, package)
  print("Cleanup complete")
end

function commands.new()
  update_gitignore()
  create_default_package_file()
end

---@param packages_dir string
function commands.nuke(packages_dir)
  if fs.isdir(packages_dir) then
    remove_file_or_dir(packages_dir)
    print("Removed packages directory: " .. packages_dir)
  else
    print("Packages directory does not exist: " .. packages_dir)
  end
end

---@param args string[]
local function main(args)
  if #args == 0 then
    help()
    os.exit(1)
  end

  local command = args[1]

  local packages_dir = fs.abspath(os.getenv(NLPM_PACKAGE_VARIABLE) or ("./" .. NLPM_PACKAGES))

  for i, arg in ipairs(args) do
    -- Handle help flags (except for run command with --)
    if not (command == "run" and args[2] == "--") then
      if arg == "--help" or arg == "-h" then
        help()
        os.exit(0)
      elseif arg == "--print-nlpm-path" then
        local nelua_path, lua_path = make_nlpm_path(packages_dir)
        print("NLPM_NELUA_PATH: '" .. nelua_path .. "'\n")
        print("NLPM_LUA_PATH: '" .. lua_path .. "'")
        os.exit(0)
      elseif arg == "--log" then
        log = true
        local sub_args = {}
        for j = 1, #args do
          if j ~= i then
            table.insert(sub_args, args[j])
          end
        end
        main(sub_args)
        os.exit(0)
      end
    end
  end

  if command == "install" then
    commands.install(packages_dir)
  elseif command == "script" then
    commands.script(packages_dir, args[2])
  elseif command == "run" then
    local start_index = (args[2] == "--") and 3 or 2
    mild_assert(args[start_index], "Command is required after 'run'")
    commands.run(packages_dir, args, start_index)
  elseif command == "clean" then
    commands.clean(packages_dir)
  elseif command == "new" then
    commands.new()
  elseif command == "nuke" then
    commands.nuke(packages_dir)
  else
    io.stderr:write("Unknown command: '" .. command .. "'\n")
    help()
    os.exit(1)
  end
end

main(arg)
