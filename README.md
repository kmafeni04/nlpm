# nlpm (NeLua Package Manager)

Package manager for Nelua projects

## WARNING

When using this, you need to run your nelua code with either the `script` or `run` command as that's the only way for the `NELUA_PATH` and `LUA_PATH` to be set correctly.

## Requirements
- [nelua](https://nelua.io)
- [git](https://git-scm.com/)

## Installation
- Clone the repo
```sh
git clone https://github.com/kmafeni04/nlpm
```

- `cd` into the folder
```sh
cd nlpm
```

- Run `nlpm`
```sh
./nlpm
```

## Package Structure

### Example
```lua
---@class PackageDependency
---@field name string package name as it will be used in file gen
---@field repo string git repo
---@field version? string git hash(#) or tag(v), defaults to "#HEAD"

---@class Package
---@field dependencies? PackageDependency[] List of package dependencies
---@field scripts? table<string, string> scripts that can be called with `nlpm script`

---@type Package
return {
  dependencies = {
    { name = "example1", repo = "https://github.com/user/mylib.git", version = "vCOMMIT_TAG" },
    { name = "example2", repo = "https://git.example.com/other.git", version = "#COMMIT_HASH" },
    { name = "example3", repo = "https://git.example.com/other.git" }, -- defaults to HEAD
  },
  scripts = {
    build = "nelua -r src/main.nelua -o build/app",
    test  = "nelua --cc=tcc test",
  }
}
```
### PackageDependency
- **name**: `string` - The name of the package as it will be used in file generation.
- **repo**: `string` - The Git repository URL of the package.
- **version**: `string?` - The Git hash (`#`) or tag (`v`) of the package. Defaults to `#HEAD`.

### Package
- **dependencies**: `PackageDependency[]?` - A list of package dependencies.
- **scripts**: `table<string, string>?` - Scripts that can be called with `nlpm script`.

## Usage
```bash
nlpm [-h] [--print-nlpm-path] [--log] <command> ...
```
### Arguements
- `runargs`: Arguments passed to the run command, use `--` to avoid conflicts with regular commands and options

### Options
- `-h, --help`: Show help message and exit.
- `--print-nlpm-path`: Print the nlpm 'NELUA_PATH' and 'LUA_PATH'
- `--log`: Enable command logging 

### Commands
- `install`: Install all dependencies from the package file.
- `clean`: Remove packages not listed in the package file.
- `script <name>`: Run a script defined in the package file with the nlpm nelua path set up.
- `run [--] <command>`: Run a command with the nlpm nelua path set up.
- `new`: Create a new package in the current directory.
- `nuke`: Delete the packages directory.

### Environment Variables
- `NLPM_PACKAGES_PATH`: Directory for package installation (default: `./nlpm_packages`).
