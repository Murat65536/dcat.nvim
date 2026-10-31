local M = {}

---@alias dcat.Layout "fullscreen"|"float"|"current"|"split"|"vsplit"|"tab"
---@alias dcat.Output "kitty"|"sixel"|"truecolor"|"palette"|"block"

---@class dcat.FloatConfig
---@field width number Columns, or a fraction of the editor width when <= 1
---@field height number Rows, or a fraction of the editor height when <= 1
---@field border string|string[]

---@class dcat.Config
---@field cmd string|string[] The dcat executable, optionally with leading arguments
---@field args string[] Extra arguments passed on every launch
---@field output? dcat.Output nil picks pixels when the terminal supports them, and characters otherwise
---@field layout dcat.Layout Where the viewer opens
---@field float dcat.FloatConfig Options for the "float" layout
---@field extensions string[] File extensions that open in dcat on :edit
M.defaults = {
  cmd = "dcat",
  args = {},
  output = nil,
  layout = "current",
  float = {
    width = 0.9,
    height = 0.9,
    border = "rounded",
  },
  -- Assimp's formats, minus ones ordinary files share and animation-only ones
  -- stylua: ignore
  extensions = {
    "3d", "3ds", "3mf", "ac3d", "acc", "amf", "ase", "ask", "assbin", "b3d",
    "blend", "bsp", "cob", "dae", "dxf", "enff", "fbx", "glb", "gltf", "hmp",
    "ifc", "ifczip", "iqm", "irr", "irrmesh", "lwo", "lws", "lxo", "md2", "md3",
    "md5mesh", "mdc", "mesh", "mesh.xml", "ms3d", "ndo", "nff", "obj", "off", "ogex",
    "ply", "pmx", "q3o", "q3s", "sib", "smd", "step", "stl", "stp", "ter",
    "vrm", "x3d", "x3db", "xgl", "zae", "zgl",
  },
}

---@type dcat.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.set(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Replace lists instead of merging them by index
  if opts and opts.extensions then
    M.options.extensions = opts.extensions
  end
  if opts and opts.args then
    M.options.args = opts.args
  end
end

---@return string[]
function M.cmd()
  local cmd = M.options.cmd
  if type(cmd) == "table" then
    return vim.deepcopy(cmd)
  end
  return { cmd }
end

return M
