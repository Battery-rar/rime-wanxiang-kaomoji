-- 万象家族 lua，颜文字输入模块
-- 编码解析交给当前方案的原生 translator / Memory；本模块只做关键词到颜文字的映射。

local wanxiang = require("wanxiang/wanxiang")

local DEFAULT_MAX_CANDIDATES = 50
local DEFAULT_SCAN_LIMIT = 100
local MAX_FALLBACK_STEPS = 6
local BOM = string.char(239, 187, 191)
local TAB = "\t"
local DEFAULT_PRESET_FILE = "lua/data/kaomoji.txt"
local DEFAULT_USER_FILE = "lua/data/kaomoji_user.txt"

local kaomoji = {}

local function trim(text)
    return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function strip_bom(text)
    return (text or ""):gsub("^" .. BOM, "")
end

local function is_absolute_path(path)
    return path and (path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" or path:match("^[A-Za-z]:[\\/]"))
end

local function open_data_file(path, mode)
    if not path or path == "" then return nil end
    if is_absolute_path(path) then return io.open(path, mode or "r") end
    return wanxiang.load_file_with_fallback(path, mode or "r")
end

local function config_string(config, path)
    local value = trim(config:get_string(path))
    return value ~= "" and value or nil
end

local function config_list(config, path)
    local values = {}
    local list = config:get_list(path)
    if not list then return values end

    for i = 0, list.size - 1 do
        local item = list:get_value_at(i)
        local value = item and trim(item.value) or ""
        if value ~= "" then values[#values + 1] = value end
    end
    return values
end

local function default_files()
    local files = {}
    local preset = wanxiang.get_filename_with_fallback(DEFAULT_PRESET_FILE)
    if preset then files[#files + 1] = preset end
    files[#files + 1] = rime_api.get_user_data_dir() .. "/" .. DEFAULT_USER_FILE
    return files
end

local function kaomoji_files(config)
    local files = config_list(config, "kaomoji/files")
    return #files > 0 and files or default_files()
end

local function literal_prefix(pattern)
    if not pattern or pattern == "" then return nil end
    if pattern:sub(1, 1) == "^" then pattern = pattern:sub(2) end

    local chars, escaped = {}, false
    for i = 1, #pattern do
        local char = pattern:sub(i, i)
        if escaped then
            chars[#chars + 1] = char
            escaped = false
        elseif char == "\\" then
            escaped = true
        elseif char:match("[%[%]%(%)%*%+%?%$%|%.]") then
            break
        else
            chars[#chars + 1] = char
        end
    end

    local prefix = table.concat(chars)
    return prefix ~= "" and prefix or nil
end

local function add_entry(index, list, seen, keyword, text)
    keyword, text = trim(keyword), trim(text)
    if keyword == "" or text == "" then return end

    local uniq = keyword .. TAB .. text
    if seen[uniq] then return end
    seen[uniq] = true

    local item = { text = text, comment = keyword }
    list[#list + 1] = item

    local bucket = index[keyword]
    if bucket then
        bucket[#bucket + 1] = item
    else
        index[keyword] = { item }
    end
end

local function load_data(files)
    local index, list, seen = {}, {}, {}

    for _, path in ipairs(files) do
        local file = open_data_file(path, "r")
        if file then
            for raw_line in file:lines() do
                local line = strip_bom(raw_line)
                if trim(line) ~= "" and not line:match("^%s*#") then
                    local keyword, text = line:match("^([^\t]+)\t(.+)$")
                    if keyword and text then add_entry(index, list, seen, keyword, text) end
                end
            end
            file:close()
        end
    end

    return index, list
end

local function query_info(input, seg, env)
    if not seg:has_tag("kaomoji") then return nil end

    local prefix = env.kaomoji_prefix
    if not prefix or prefix == "" or input:sub(1, #prefix) ~= prefix then return nil end

    local query = input:sub(#prefix + 1):lower()
    return { raw_input = input, query = query }
end

local function limit_reached(yielded)
    return (yielded.__count or 0) >= DEFAULT_MAX_CANDIDATES
end

local apply_tone_preedit

local function emit_items(items, seg, raw_input, env, yielded)
    if not items then return 0 end

    local count = 0
    for _, item in ipairs(items) do
        if limit_reached(yielded) then break end
        if not yielded[item.text] then
            yielded[item.text] = true
            local cand = Candidate("kaomoji", seg.start, seg._end, item.text, item.comment)
            cand.quality = 1000000 - (yielded.__count or 0)
            cand.preedit = apply_tone_preedit(env, raw_input)
            yield(cand)
            count = count + 1
            yielded.__count = (yielded.__count or 0) + 1
        end
    end
    return count
end

local function emit_by_keyword(keyword, seg, raw_input, env, yielded)
    return emit_items(env.kaomoji_index[keyword], seg, raw_input, env, yielded)
end

local function query_translator(query, seg, raw_input, env, yielded)
    if not env.kaomoji_translator then return 0 end

    local scan_count, yield_count = 0, 0
    local query_seg = Segment(0, #query)
    query_seg.tags = Set({ "abc" })

    local ok, translation = pcall(function()
        return env.kaomoji_translator:query(query, query_seg)
    end)
    if not ok or not translation then return 0 end

    for cand in translation:iter() do
        if limit_reached(yielded) then break end
        scan_count = scan_count + 1
        yield_count = yield_count + emit_by_keyword(cand.text, seg, raw_input, env, yielded)
        if limit_reached(yielded) or scan_count >= DEFAULT_SCAN_LIMIT then break end
    end
    return yield_count
end

local function query_memory(query, seg, raw_input, env, yielded)
    if not env.kaomoji_memory then return 0 end

    local yield_count = 0
    if env.kaomoji_memory:dict_lookup(query, true, DEFAULT_SCAN_LIMIT) then
        for entry in env.kaomoji_memory:iter_dict() do
            if limit_reached(yielded) then return yield_count end
            yield_count = yield_count + emit_by_keyword(entry.text, seg, raw_input, env, yielded)
            if limit_reached(yielded) then return yield_count end
        end
    end

    if env.kaomoji_memory:user_lookup(query, true) then
        for entry in env.kaomoji_memory:iter_user() do
            if limit_reached(yielded) then break end
            yield_count = yield_count + emit_by_keyword(entry.text, seg, raw_input, env, yielded)
            if limit_reached(yielded) then break end
        end
    end
    return yield_count
end

local function query_native(query, seg, raw_input, env, yielded)
    local count = query_translator(query, seg, raw_input, env, yielded)
    if not limit_reached(yielded) then
        count = count + query_memory(query, seg, raw_input, env, yielded)
    end
    return count
end

local function get_tone_preedit_map(env)
    if env.kaomoji_tone_map then
        return env.kaomoji_tone_map
    end

    local tone_map = {}
    local cfg = env.engine and env.engine.schema and env.engine.schema.config
    for d = 0, 9 do
        local key = tostring(d)
        local value = cfg and cfg:get_string("tone_preedit/" .. key)
        tone_map[key] = (value and value ~= "") and value or key
    end

    env.kaomoji_tone_map = tone_map
    return tone_map
end

apply_tone_preedit = function(env, preedit)
    if not preedit or preedit == "" then
        return preedit
    end

    local tone_map = get_tone_preedit_map(env)
    return preedit:gsub("([^%d%s]+)(%d+)", function(body, digits)
        local mapped = digits:gsub("%d", function(d)
            return tone_map[d] or d
        end)
        return body .. mapped
    end)
end

function kaomoji.init(env)
    local config = env.engine.schema.config
    env.kaomoji_prefix = literal_prefix(config_string(config, "recognizer/patterns/kaomoji"))
    env.kaomoji_index, env.kaomoji_list = load_data(kaomoji_files(config))
    env.kaomoji_memory = Memory and Memory(env.engine, env.engine.schema) or nil

    if Component and Component.Translator then
        pcall(function()
            env.kaomoji_translator = Component.Translator(env.engine, "translator", "script_translator")
        end)
    end
end

function kaomoji.func(input, seg, env)
    local info = query_info(input, seg, env)
    if not info then return end

    local yielded = {}

    if info.query == "" then
        emit_items(env.kaomoji_list, seg, info.raw_input, env, yielded)
        return
    end

    local query = info.query
    local fallback_steps = 0
    while true do
        local count = query_native(query, seg, info.raw_input, env, yielded)
        if count > 0 then
            return
        end

        if fallback_steps >= MAX_FALLBACK_STEPS then
            emit_items(env.kaomoji_list, seg, info.raw_input, env, yielded)
            return
        end

        query = query:sub(1, #query - 1)
        fallback_steps = fallback_steps + 1
        if query == "" then
            emit_items(env.kaomoji_list, seg, info.raw_input, env, yielded)
            return
        end
    end
end

return kaomoji
