-- Highlight groups. The diff groups are derived from the colorscheme instead of
-- plain links, because themes disagree on what Diff* contain: some set an fg
-- (which would wipe out syntax colors under our extmarks), some use DiffText
-- for "changed" with light text on a dark bg (unreadable as a token overlay),
-- some give DiffDelete no bg at all.
--
-- Derivation, in OKLab, from the theme's Normal, DiffAdd and DiffDelete:
--   line bg  = DiffAdd / DiffDelete bg (fallback: Added / Removed fg blended
--              into Normal bg);
--   token bg = the line bg pushed further from Normal bg (same hue, more
--              chroma), then pulled back in lightness until Normal fg keeps at
--              least min(4.5, contrast it has on the line bg) against it;
--   tokens and added lines are bg-only, so syntax colors stay visible;
--   deleted lines are virtual text (no syntax): their fg is picked for contrast.
--
-- Groups the user defined themselves are left alone. Recomputed on
-- ColorScheme and when 'background' changes.

local M = {}

-- color math -------------------------------------------------------------------------

local function to_rgb(n)
    return { bit.rshift(n, 16) / 255, bit.band(bit.rshift(n, 8), 255) / 255, bit.band(n, 255) / 255 }
end

local function to_int(c)
    local function ch(x) return math.floor(math.min(1, math.max(0, x)) * 255 + 0.5) end
    return ch(c[1]) * 65536 + ch(c[2]) * 256 + ch(c[3])
end

local function lin(x) return x <= 0.04045 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4 end
local function delin(x) return x <= 0.0031308 and x * 12.92 or 1.055 * x ^ (1 / 2.4) - 0.055 end
local function cbrt(x) return x < 0 and -((-x) ^ (1 / 3)) or x ^ (1 / 3) end

local function oklab(n)
    local c = to_rgb(n)
    local r, g, b = lin(c[1]), lin(c[2]), lin(c[3])
    local l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    local m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    local s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return {
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    }
end

-- OKLab -> linear sRGB (may be out of gamut)
local function lab_lin(p)
    local l = (p[1] + 0.3963377774 * p[2] + 0.2158037573 * p[3]) ^ 3
    local m = (p[1] - 0.1055613458 * p[2] - 0.0638541728 * p[3]) ^ 3
    local s = (p[1] - 0.0894841775 * p[2] - 1.2914855480 * p[3]) ^ 3
    return {
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    }
end

local function in_gamut(c)
    for _, x in ipairs(c) do
        if x < -1e-4 or x > 1 + 1e-4 then return false end
    end
    return true
end

--- OKLab -> int, reducing chroma (keeping lightness and hue) to fit sRGB.
local function from_lab(p)
    local function at(k) return lab_lin({ p[1], p[2] * k, p[3] * k }) end
    local c = at(1)
    if not in_gamut(c) then
        local lo, hi = 0, 1
        for _ = 1, 20 do
            local mid = (lo + hi) / 2
            if in_gamut(at(mid)) then lo = mid else hi = mid end
        end
        c = at(lo)
    end
    return to_int({ delin(c[1]), delin(c[2]), delin(c[3]) })
end

local function luminance(n)
    local c = to_rgb(n)
    return 0.2126 * lin(c[1]) + 0.7152 * lin(c[2]) + 0.0722 * lin(c[3])
end

function M.contrast(x, y)
    local a, b = luminance(x), luminance(y)
    if a < b then a, b = b, a end
    return (a + 0.05) / (b + 0.05)
end

local function delta(x, y) -- perceptual distance (OKLab ΔE)
    local a, b = oklab(x), oklab(y)
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
end

-- theme colors ---------------------------------------------------------------------------

local function get(name)
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and h or {}
end

local function normal()
    local h = get("Normal")
    local dark = vim.o.background == "dark"
    local fg, bg = h.fg, h.bg
    if h.reverse then fg, bg = bg, fg end
    return fg or (dark and 0xdcdcdc or 0x1e1e1e), bg or (dark and 0x1e1e1e or 0xf8f8f8)
end

--- Effective { fg, bg } of a group, honoring `reverse`; missing parts are nil.
local function colors(name)
    local h = get(name)
    if h.reverse then
        local nfg, nbg = normal()
        return h.bg or nbg, h.fg or nfg
    end
    return h.fg, h.bg
end

--- Background of a diff line group. Without one, Normal bg tinted with the
--- group's (or `accent_group`'s) hue, at Normal bg's lightness so every text
--- color keeps its usual contrast.
local function line_bg(group, accent_group, accent, nbg)
    local _, bg = colors(group)
    if bg and bg ~= nbg then return bg end
    local A, N = oklab(colors(group) or colors(accent_group) or accent), oklab(nbg)
    local c = math.max(math.sqrt(A[2] ^ 2 + A[3] ^ 2), 1e-6)
    return from_lab({ N[1], A[2] / c * 0.06, A[3] / c * 0.06 })
end

--- Token bg: same hue as the line bg with more chroma, as far from Normal bg as
--- readability allows. Every text color in `fgs` must keep min(4.5, its
--- contrast on the line bg): tokens are never harder to read than the theme's
--- own diff lines.
function M.emphasize(line, nbg, fgs)
    local L, N = oklab(line), oklab(nbg)
    local chroma = math.sqrt(L[2] ^ 2 + L[3] ^ 2)
    local da, db = L[2] / math.max(chroma, 1e-6), L[3] / math.max(chroma, 1e-6)
    local tc = math.max(chroma * 2, chroma + 0.05)
    -- t = 1: twice as far from Normal bg as the line (at least a small step,
    -- for a line bg that is only a tint of Normal bg)
    local dl = L[1] - N[1]
    local away = vim.o.background == "dark" and 1 or -1
    if math.abs(dl) < 0.06 then dl = (dl ~= 0 and (dl > 0 and 1 or -1) or away) * 0.06 end
    local targets = {}
    for i, fg in ipairs(fgs) do targets[i] = math.min(4.5, M.contrast(fg, line)) end
    local function readable(c)
        for i, fg in ipairs(fgs) do
            if M.contrast(fg, c) < targets[i] - 0.05 then return false end
        end
        return true
    end
    -- most emphasis first; past t = 0 the lightness moves back toward Normal
    -- bg (keeping the extra chroma), which only raises text contrast
    local best, best_d
    for t = 1, -1, -0.05 do
        local c = from_lab({ L[1] + t * dl, da * tc, db * tc })
        if readable(c) then
            local d = delta(c, line)
            if d >= 0.05 then return c end -- stands out from the line
            if not best_d or d > best_d then best, best_d = c, d end
        end
    end
    return best or line
end

local text_groups = {
    "String", "Character", "Number", "Boolean", "Constant", "Identifier", "Function",
    "Statement", "Keyword", "Conditional", "Repeat", "Operator", "Type", "Special",
    "PreProc", "Comment", "Delimiter", "@variable", "@variable.member", "@property",
    "@keyword", "@function", "@function.call", "@string", "@type", "@constant",
}

--- Readable text color on `bg`: Normal fg when it passes AA, else whichever of
--- Normal fg / Normal bg contrasts more.
local function text_on(bg, nfg, nbg)
    if M.contrast(nfg, bg) >= 4.5 then return nfg end
    return M.contrast(nbg, bg) > M.contrast(nfg, bg) and nbg or nfg
end

-- groups -----------------------------------------------------------------------------

local links = {
    ReviewCommentSign = "DiagnosticSignInfo",
    ReviewCommentText = "DiagnosticVirtualTextInfo",
    ReviewQuestionSign = "DiagnosticSignWarn",
    ReviewQuestionText = "DiagnosticVirtualTextWarn",
    ReviewModeActive = "PmenuSel",
}

-- without 'termguicolors' there is nothing to compute from
local cterm_links = {
    ReviewDifftAdd = "DiffAdd",
    ReviewDifftDelete = "DiffDelete",
    ReviewInlineAdd = "DiffAdd",
    ReviewInlineAddText = "DiffText",
    ReviewInlineDelete = "DiffDelete",
    ReviewInlineDeleteText = "DiffText",
    ReviewInlineDeleteNr = "DiffDelete",
    ReviewDeleteLine = "DiffDelete",
    ReviewMode = "Comment",
}

function M.specs()
    local specs = {}
    for name, link in pairs(links) do specs[name] = { link = link } end
    if not vim.o.termguicolors then
        for name, link in pairs(cterm_links) do specs[name] = { link = link } end
        return specs
    end

    local nfg, nbg = normal()
    local add = line_bg("DiffAdd", "Added", 0x2ea043, nbg)
    local del = line_bg("DiffDelete", "Removed", 0xf85149, nbg)
    -- token overlays keep syntax colors: check them all, not just Normal
    local fgs, seen = { nfg }, { [nfg] = true }
    for _, g in ipairs(text_groups) do
        local fg = colors(g)
        if fg and not seen[fg] then fgs[#fgs + 1], seen[fg] = fg, true end
    end
    local add_tok = M.emphasize(add, nbg, fgs)
    local del_tok = M.emphasize(del, nbg, fgs)
    local del_fg = text_on(del, nfg, nbg)

    specs.ReviewDifftAdd = { bg = add_tok }
    specs.ReviewDifftDelete = { bg = del_tok }
    specs.ReviewDeleteLine = { bg = del }
    specs.ReviewInlineAdd = { bg = add }
    specs.ReviewInlineAddText = { bg = add_tok }
    specs.ReviewInlineDelete = { bg = del, fg = del_fg }
    specs.ReviewInlineDeleteText = { bg = del_tok, fg = text_on(del_tok, nfg, nbg) }
    local nr = colors("LineNr")
    specs.ReviewInlineDeleteNr = { bg = del, fg = (nr and M.contrast(nr, del) >= 3) and nr or del_fg }

    -- inactive mode names in the winbar (fg only: the bar's bg shows through):
    -- Comment, unless it's too faint on WinBar or WinBarNC
    local wfg, wbg = colors("WinBar")
    local _, wbg_nc = colors("WinBarNC")
    local cfg = colors("Comment")
    local faint = not cfg
        or M.contrast(cfg, wbg or nbg) < 3
        or M.contrast(cfg, wbg_nc or wbg or nbg) < 3
    specs.ReviewMode = { fg = faint and (wfg or nfg) or cfg }
    return specs
end

local owned = {} -- name -> definition as we last set it

function M.apply()
    for name, spec in pairs(M.specs()) do
        local cur = vim.api.nvim_get_hl(0, { name = name })
        -- a group defined by someone else (user config) is theirs
        if vim.tbl_isempty(cur) or vim.deep_equal(cur, owned[name]) then
            vim.api.nvim_set_hl(0, name, spec)
            owned[name] = vim.api.nvim_get_hl(0, { name = name })
        end
    end
end

function M.setup()
    M.apply()
    local group = vim.api.nvim_create_augroup("review.highlights", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.apply })
    vim.api.nvim_create_autocmd("OptionSet", {
        group = group,
        pattern = { "background", "termguicolors" },
        callback = function() vim.schedule(M.apply) end,
    })
end

return M
