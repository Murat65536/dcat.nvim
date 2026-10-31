# dcat.nvim

View 3D models in Neovim with [dcat](https://github.com/Murat65536/dcat).
Opening a model file shows it in dcat instead of as text.

## Requirements

- Neovim 0.12+
- [dcat](https://github.com/Murat65536/dcat#install) on your `PATH`

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Murat65536/dcat.nvim",
  opts = {},
}
```

## Usage

```vim
:Dcat                     " view the current buffer's file
:Dcat model.glb           " view a file
:Dcat model.glb --spin 1  " pass any dcat flags
```

`q` closes the viewer. After closing a model you opened with `:e`, press `e` to edit it as text.

Models are drawn in pixels in terminals that support the Kitty graphics protocol or Sixel, and with text characters elsewhere.
`:checkhealth dcat` shows which you get.

## Configuration

The defaults:

```lua
require("dcat").setup({
  cmd = "dcat",       -- the dcat executable
  args = {},          -- flags passed on every launch
  output = nil,       -- "kitty", "sixel", "truecolor", "palette" or "block"; nil picks automatically
  layout = "current", -- "current", "fullscreen", "float", "split", "vsplit" or "tab"
})
```

See `:help dcat` for everything else.
