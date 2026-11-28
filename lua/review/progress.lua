-- Per-file "reviewed" marks, persisted per branch next to the notes file
-- (<branch>.reviewed.json). Each mark stores the git blob hash of the file
-- when it was marked, so a file edited afterwards shows as changed again.

local util = require("review.util")

local M = {}

local marks, loaded_file = {}, nil -- rel path -> blob hash

local function store_path(c)
    return (c.notes:gsub("%.md$", "")) .. ".reviewed.json"
end

local function load()
    local c = util.ctx()
    if not c then return nil end
    local p = store_path(c)
    if loaded_file ~= p then
        marks = {}
        local f = io.open(p, "r")
        if f then
            local ok, data = pcall(vim.json.decode, f:read("a"))
            f:close()
            if ok and type(data) == "table" and type(data.files) == "table" then marks = data.files end
        end
        loaded_file = p
    end
    return c
end

local function save(c)
    local p = store_path(c)
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local files = next(marks) and marks or vim.empty_dict()
    vim.fn.writefile({ vim.json.encode({ files = files }) }, p)
end

--- Current blob hashes of the given repo files (missing files are skipped).
local function hashes(c, rels)
    local present = vim.tbl_filter(function(r) return vim.uv.fs_stat(c.root .. "/" .. r) ~= nil end, rels)
    local out = {}
    if #present == 0 then return out end
    local args = { "hash-object", "--" }
    vim.list_extend(args, present)
    local res = util.git(args, c.root)
    if not res then return out end
    local lines = vim.split(res, "\n", { plain = true })
    for i, r in ipairs(present) do out[r] = lines[i] end
    return out
end

--- rel -> "done" | "stale" for the marked files among rels.
function M.status(rels)
    local c = load()
    local res = {}
    if not c then return res end
    local marked = vim.tbl_filter(function(r) return marks[r] ~= nil end, rels)
    local h = hashes(c, marked)
    for _, r in ipairs(marked) do
        res[r] = h[r] == marks[r] and "done" or "stale"
    end
    return res
end

local prefix = { done = "[x] ", stale = "[~] " }

--- Set the status and text of changed-files quickfix items.
--- Returns the number of files marked as reviewed (and unchanged since).
function M.decorate(items)
    local rels = vim.tbl_map(function(it) return it.user_data.path end, items)
    local st = M.status(rels)
    local done = 0
    for _, it in ipairs(items) do
        local u = it.user_data
        local s = st[u.path]
        u.status = s
        if s == "done" then done = done + 1 end
        it.text = u.stat .. (s == "stale" and "  (changed since reviewed)" or "")
    end
    return done
end

--- 'quickfixtextfunc' of the changed-files list: the default quickfix line
--- ("<filename>|<lnum> col <col>|<text>") with the reviewed marker moved in
--- front of the file name.
function M.qf_text(info)
    local items = vim.fn.getqflist({ id = info.id, items = 1 }).items
    local lines = {}
    for i = info.start_idx, info.end_idx do
        local it = items[i]
        local name = it.bufnr > 0 and vim.fn.bufname(it.bufnr) or ""
        if name ~= "" then name = vim.fn.fnamemodify(name, ":p:.") end
        local pos = it.lnum > 0 and tostring(it.lnum) or ""
        if pos ~= "" and it.col > 0 then pos = pos .. " col " .. it.col end
        local u = it.user_data
        local line = (prefix[type(u) == "table" and u.status] or "[ ] ") .. name .. "|" .. pos
        if type(it.text) == "string" and it.text ~= "" then line = line .. "| " .. it.text end
        lines[#lines + 1] = line
    end
    return lines
end

function M.is_files_list(ctx)
    return type(ctx) == "table" and ctx.review_files == true
end

--- Redraw the changed-files quickfix list(s) in place, keeping the position.
function M.refresh_qf()
    local last = vim.fn.getqflist({ nr = "$" }).nr
    for nr = 1, last do
        local l = vim.fn.getqflist({ nr = nr, id = 0, context = 0, items = 0, idx = 0 })
        if M.is_files_list(l.context) and #l.items > 0 then
            local done = M.decorate(l.items)
            local views = {}
            for _, w in ipairs(vim.fn.getwininfo()) do
                if w.quickfix == 1 and w.loclist == 0 then
                    views[w.winid] = vim.api.nvim_win_call(w.winid, vim.fn.winsaveview)
                end
            end
            vim.fn.setqflist({}, "r", {
                id = l.id,
                items = l.items,
                idx = l.idx,
                title = l.context.title:format(done),
            })
            for win, v in pairs(views) do
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_call(win, function() vim.fn.winrestview(v) end)
                end
            end
        end
    end
end

--- Files targeted by :ReviewMark: quickfix entries in l1..l2 when in the
--- changed-files quickfix window, else the current buffer's file.
local function targets(l1, l2)
    if vim.fn.win_gettype() == "quickfix" then
        local l = vim.fn.getqflist({ context = 0, items = 0 })
        if not M.is_files_list(l.context) then return nil, "not the review files list" end
        local rels = {}
        for i = l1, l2 do
            local it = l.items[i]
            if it and type(it.user_data) == "table" and it.user_data.path then
                table.insert(rels, it.user_data.path)
            end
        end
        return rels
    end
    local rel = util.relpath(0)
    if not rel then return nil, "buffer is not a file in this repository" end
    return { rel }
end

--- Toggle the reviewed mark: unmarks if all targets are reviewed, else marks
--- them all (re-marking files changed since they were reviewed).
function M.toggle(l1, l2)
    local c = load()
    if not c then return util.notify("not in a git repository", vim.log.levels.WARN) end
    l1 = l1 or vim.fn.line(".")
    l2 = l2 or l1
    if l1 > l2 then l1, l2 = l2, l1 end
    local rels, err = targets(l1, l2)
    if not rels then return util.notify(err, vim.log.levels.WARN) end
    if #rels == 0 then return end

    local st = M.status(rels)
    local all_done = true
    for _, r in ipairs(rels) do
        if st[r] ~= "done" then all_done = false break end
    end
    if all_done then
        for _, r in ipairs(rels) do marks[r] = nil end
    else
        local h = hashes(c, rels)
        for _, r in ipairs(rels) do marks[r] = h[r] or marks[r] end
    end
    save(c)
    M.refresh_qf()
    if vim.fn.win_gettype() ~= "quickfix" then
        util.notify((all_done and "unmarked: " or "reviewed: ") .. table.concat(rels, ", "))
    end
end

return M
