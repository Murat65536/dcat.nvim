# dcat.nvim

Neovim 3d model viewer with [dcat](https://github.com/Murat65536/dcat).

## Requirements

- Neovim 0.12+
- [dcat](https://github.com/Murat65536/dcat#install) 1.4.0+

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

`<C-c>` closes the viewer. After closing a model you opened with `:e`, press `e` to edit it as text.

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
