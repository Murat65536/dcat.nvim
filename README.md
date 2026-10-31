# dcat.nvim

View 3D models in Neovim with [dcat](https://github.com/Murat65536/dcat).

- Opening any 3D model (`:e`, a picker, a file explorer) shows it in dcat instead of as text
- `:Dcat model.glb` opens a model directly
- dcat errors, like an unreadable model, show up as notifications

## Requirements

- Neovim 0.10+
- [dcat](https://github.com/Murat65536/dcat#install) on your `PATH`

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Murat65536/dcat.nvim",
  opts = {},
}
```

The plugin works without calling `setup()`, using the defaults below.

Run `:checkhealth dcat` to check that dcat is found.

## Usage

```vim
:Dcat                     " view the current buffer's file
:Dcat model.glb           " view a file
:Dcat model.glb --spin 1  " pass any dcat flags
```

The viewer is an ordinary window, so splits, file explorers and window commands work around it.
In it, keys go to dcat (`dcat --controls` lists them) and `q` closes it, except for these, which go to Neovim:

- `<C-w>` window commands and `:` commands
- your normal-mode mappings that are a single Ctrl or Alt key, like a `<C-n>` that toggles a file tree

Going back to the viewer's window gives dcat the keys again.

Closing a model you opened leaves an empty buffer for it. There, `<CR>` reopens the viewer and `e` loads the file as text to edit.

From Lua:

```lua
require("dcat").open("model.glb", { args = { "--mouse-orbit" }, layout = "vsplit" })
```

## Configuration

```lua
require("dcat").setup({
  -- The dcat executable, optionally with leading arguments
  cmd = "dcat",
  -- Extra arguments passed on every launch, e.g. { "--mouse-orbit", "--status-bar" }
  args = {},
  -- "truecolor", "palette" or "block". nil picks truecolor when 'termguicolors' is set
  output = nil,
  -- "current" (the window the model opened in), "fullscreen" (a float over the
  -- whole editor), "float", "split", "vsplit" or "tab"
  layout = "current",
  -- Used by the "float" layout
  float = {
    -- Cells, or a fraction of the editor size when <= 1
    width = 0.9,
    height = 0.9,
    border = "rounded",
  },
  -- Extensions that open in dcat on :edit. {} turns this off. The default is
  -- every format dcat reads, e.g. glb, gltf, obj, fbx, stl, ply, dae, 3ds, blend.
  -- See lua/dcat/config.lua for the full list.
  extensions = { ... },
})
```

A few formats dcat reads aren't in the default list because ordinary files share their extensions: `ac` (`configure.ac`), `x`, `xml`, `raw`, `mot`, `prj`, `uc`, `mdl`, `scn` and `pk3`.
Formats that hold only animation or camera data (`bvh`, `csm`, `md5anim`, `md5camera`, `vta`) are left out too.
To add some back:

```lua
local extensions = vim.deepcopy(require("dcat.config").defaults.extensions)
vim.list_extend(extensions, { "x", "mdl" })
require("dcat").setup({ extensions = extensions })
```

### Output modes

Neovim's terminal can't display the Kitty or Sixel graphics protocols, so the plugin always runs dcat in a character mode.
Without this, dcat would pick a graphics protocol from the environment variables it inherits from the terminal running Neovim.
