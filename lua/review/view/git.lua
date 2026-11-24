-- Plain Neovim diff mode: alignment and highlights come from 'diffopt'.
local M = {}

function M.available()
    return true
end

function M.enable(_) end

function M.disable(_) end

-- Neovim's changed-text highlight: removed on the base side, added on yours
M.text_hl = { base = "ReviewDifftDelete", src = "ReviewDifftAdd" }

return M
