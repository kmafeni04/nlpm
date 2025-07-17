---@class PackageDependency
---@field name string
---@field repo string
---@field version? string

---@class Package
---@field dependencies? PackageDependency[]
---@field scripts? table<string, string>

local fs = require("nelua.utils.fs")
local lfs = require("lfs")

local package_name <const> = "nl_package"
local root_dir <const> = lfs.currentdir()

---@param ok any
---@param err string?
local function mild_assert(ok, err)
  if not ok then
    io.stderr:write((err and err or "Assert hit") .. "\n")
    os.exit(1)
  end
end

local function run_command(cmd)
  local on_windows = package.config:sub(1, 1) == "\\"
  if on_windows then
    return os.execute(cmd .. " > NUL 2>&1")
  else
    return os.execute(cmd .. " > /dev/null 2>&1")
    -- return os.execute(cmd)
  end
end

---@param path string
local function remove_file_or_dir(path)
  if lfs.attributes(path).mode == "directory" then
    for file in lfs.dir(path) do
      if file ~= "." and file ~= ".." then
        local sub_path = path .. "/" .. file
        local attr = lfs.attributes(sub_path)
        if attr.mode == "directory" then
          remove_file_or_dir(sub_path)
        else
          os.remove(sub_path)
        end
      end
    end
    lfs.rmdir(path)
  else
    os.remove(path)
  end
end

---@param package_dir string
---@return string[]
local function get_packages(package_dir)
  local packages = {}
  for package in lfs.dir(package_dir) do
    table.insert(packages, fs.abspath(package_dir .. "/" .. package) .. "/?.nelua")
    table.insert(packages, fs.abspath(package_dir .. "/" .. package) .. "/?/init.nelua")
  end
  return packages
end

---@param dependency PackageDependency
---@return string
---@return string
---@return string
local function gen_dep_name(dependency)
  local dep_type = ""
  local dep_version = ""
  if dependency.version then
    mild_assert(dependency.version ~= "")
    dep_type, dep_version = dependency.version:match("([%#v])(.+)")
    mild_assert(dep_type)
  else
    dep_type = "#"
    dep_version = "HEAD"
  end
  return ("%s@%s%s"):format(dependency.name, dep_type, dep_version), dep_type, dep_version
end

---@param package_dir string
---@param dependency PackageDependency
local function install(package_dir, dependency, depth)
  if not fs.isdir(package_dir) then
    lfs.mkdir(package_dir)
  end
  local ok, err = lfs.chdir(package_dir)
  mild_assert(ok, err)
  local folder_name, dep_type, dep_version = gen_dep_name(dependency)
  if dep_version == "HEAD" and fs.isdir(folder_name) and not depth then
    remove_file_or_dir(folder_name)
  end
  if not fs.isdir(folder_name) then
    print(('Installing pacakage "%s"...'):format(folder_name))
    ok, err = run_command(("git clone --depth 1 %s %s "):format(dependency.repo, folder_name))
    mild_assert(ok, err)
    ok, err = lfs.chdir(folder_name)
    mild_assert(ok, err)
    if fs.isfile(package_name .. ".lua") then
      local current_dir = lfs.currentdir()
      lfs.chdir(root_dir)
      local sub_require_path = (package_dir):sub(#root_dir + 2) .. "." .. folder_name .. "." .. package_name
      local sub_package = require(sub_require_path)--[[@as Package]]
      if sub_package.dependencies then
        for _, dep in ipairs(sub_package.dependencies) do
          install(package_dir, dep, true)
        end
      end
      lfs.chdir(current_dir)
    end
    local tag = dep_type == "v"
    ok, err = run_command("git fetch origin " .. dep_version)
    mild_assert(ok, err)
    ok, err = run_command(("git checkout %s"):format(tag and dep_type .. dep_version or dep_version))
    mild_assert(ok, err)
    remove_file_or_dir(".git")
    lfs.chdir(package_dir)
  elseif dep_version ~= "HEAD" then
    print(('Skipping package: "%s", already exists'):format(folder_name))
  end
end

local function clean(package_dir, package)
  print("Cleaning up unmarked packages...")
  if not package.dependencies then
    return
  end
  local dependency_name = {}
  for _, dep in ipairs(package.dependencies) do
    local name = gen_dep_name(dep)
    dependency_name[name] = true
  end
  local ok, err = lfs.chdir(package_dir)
  mild_assert(ok, err)
  for k in pairs(dependency_name) do
    ok, err = lfs.chdir(k)
    mild_assert(ok, err)
    if fs.isfile(package_name .. ".lua") then
      local sub_require_path = (package_dir):sub(#root_dir + 2) .. "." .. k .. "." .. package_name
      local sub_package = require(sub_require_path)--[[@as Package]]
      if sub_package.dependencies then
        for _, dep in ipairs(sub_package.dependencies) do
          local name = gen_dep_name(dep)
          dependency_name[name] = true
        end
      end
    end
    ok, err = lfs.chdir(package_dir)
    mild_assert(ok, err)
  end
  for path in lfs.dir(".") do
    if path ~= "." and path ~= ".." then
      if not dependency_name[path] then
        remove_file_or_dir(fs.abspath(path))
      end
    end
  end
end

local function help()
  print([[Usage: nlpm [-h] <command> ...

Options:
   -h, --help     Show this help message and exit.

Commands:
   install        Installs all packages in your nlpm_package.lua file into your nlpm_packages directory
   clean          Removes any packages not listed in your nlpm_package.lua file
   run            Runs a script specified in your nlpm_package.lua file
]])
end

if #arg == 0 then
  help()
  os.exit(1)
end

for _, v in ipairs(arg) do
  if v == "--help" or v == "-h" then
    help()
    os.exit()
  end
end

local package_dir = fs.abspath(os.getenv("NLPM_PACKAGE_PATH") or "./nlpm_packages")

---@type Package
local package = require(package_name)

if arg[1] == "install" then
  print("Installing packages...")
  for _, dependency in ipairs(package.dependencies) do
    install(package_dir, dependency)
  end
  print("Done installing packages")
  clean(package_dir, package)
  print("Done cleaning up")
elseif arg[1] == "run" then
  local script_name = arg[2]
  mild_assert(script_name, "run command requires a script name")
  local script = package.scripts[script_name]
  mild_assert(script, ("script_name: '%s' could not be found"):format(script_name))
  local packages = get_packages(package_dir)
  os.execute(
    ("NELUA_PATH='./?.nelua;./?/init.nelua;/usr/local/lib/nelua/lib/?.nelua;/usr/local/lib/nelua/lib/?/init.nelua;%s' %s"):format(
      table.concat(packages, ";"),
      script
    )
  )
elseif arg[1] == "clean" then
  clean(package_dir, package)
  print("Done cleaning up")
end
