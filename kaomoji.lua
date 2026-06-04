-- 万象家族 lua，颜文字输入模块
-- 目标：
-- 1. /km 之类的前缀始终保留
-- 2. 查询链路固定为：提示词 -> 拼音 -> 主翻译器 -> 词语 -> 映射到 kaomoji

local wanxiang = require("wanxiang/wanxiang")

local DEFAULT_MAX_CANDIDATES = 80
local BOM = string.char(239, 187, 191)
local TAB = "\t"
local DEFAULT_PRESET_FILE = "lua/data/kaomoji.txt"
local DEFAULT_USER_FILE = "lua/data/kaomoji_user.txt"

local kaomoji = {
    entries_signature = nil,
    entries = {},
    entries_by_key = {},
}

local function trim(text)
    return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function strip_bom(text)
    if not text then
        return ""
    end
    return text:gsub("^" .. BOM, "")
end

local function is_absolute_path(path)
    if not path then
        return false
    end
    return path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" or path:match("^[A-Za-z]:[\\/]")
end

local function close_file(file, close_fn)
    if close_fn then
        close_fn()
    elseif file then
        file:close()
    end
end

local function open_data_file(path, mode)
    if not path or path == "" then
        return nil
    end
    if is_absolute_path(path) then
        return io.open(path, mode or "r")
    end
    return wanxiang.load_file_with_fallback(path, mode)
end

local function get_config_list(config, path)
    local values = {}
    local list = config:get_list(path)
    if not list then
        return values
    end

    for i = 0, list.size - 1 do
        local item = list:get_value_at(i)
        local value = item and trim(item.value) or ""
        if value ~= "" then
            values[#values + 1] = value
        end
    end
    return values
end

local function get_config_string(config, path)
    local value = config:get_string(path)
    value = value and trim(value) or ""
    return value ~= "" and value or nil
end

local function get_config_bool(config, path, default_value)
    local value = config:get_bool(path)
    if value == nil then
        return default_value
    end
    return value
end

local function get_default_kaomoji_files()
    local files = {}
    local preset = wanxiang.get_filename_with_fallback(DEFAULT_PRESET_FILE)
    local user_file = rime_api.get_user_data_dir() .. "/" .. DEFAULT_USER_FILE

    if preset then
        files[#files + 1] = preset
    end
    files[#files + 1] = user_file
    return files
end

local function get_kaomoji_files(config)
    local files = get_config_list(config, "kaomoji/files")
    if #files > 0 then
        return files
    end
    return get_default_kaomoji_files()
end

local function extract_query_prefix(pattern)
    if not pattern or pattern == "" then
        return nil
    end

    local source = pattern
    local prefix = {}
    local escaped = false

    if source:sub(1, 1) == "^" then
        source = source:sub(2)
    end

    for i = 1, #source do
        local char = source:sub(i, i)
        if escaped then
            prefix[#prefix + 1] = char
            escaped = false
        elseif char == "\\" then
            escaped = true
        elseif char:match("[%[%]%(%)%*%+%?%$%|%.]") then
            break
        else
            prefix[#prefix + 1] = char
        end
    end

    local literal_prefix = table.concat(prefix, "")
    return literal_prefix ~= "" and literal_prefix or nil
end

local function get_query_prefix(config)
    return extract_query_prefix(get_config_string(config, "recognizer/patterns/kaomoji"))
end

local function get_allowed_query_chars(config)
    local allowed = {}
    local alphabet = get_config_string(config, "speller/alphabet") or ""
    local delimiter = get_config_string(config, "speller/delimiter") or ""

    for i = 1, #alphabet do
        allowed[alphabet:sub(i, i):lower()] = true
    end
    for i = 1, #delimiter do
        allowed[delimiter:sub(i, i):lower()] = true
    end
    local tone_digits = "7890"
    for i = 1, #tone_digits do
        allowed[tone_digits:sub(i, i)] = true
    end

    return allowed
end

local function is_valid_query_char(char, allowed_chars)
    return allowed_chars[char:lower()] == true
end

local function get_translator_path(config)
    local translators = config:get_list("engine/translators")
    if translators then
        for i = 0, translators.size - 1 do
            local item = translators:get_value_at(i)
            local value = item and trim(item.value) or ""
            local class_name, path = value:match("^([^@]+)@(.+)$")
            if not class_name then
                class_name = value
                path = value == "script_translator" and "translator" or value
            end
            if class_name == "script_translator" then
                return path, class_name
            end
        end
    end

    return "translator", "script_translator"
end

local function get_file_signature(path)
    local file, close_fn = open_data_file(path, "rb")
    if not file then
        return path .. "::missing"
    end

    local size = file:seek("end") or 0
    local head, mid, tail = "", "", ""
    if size > 0 then
        file:seek("set", 0)
        head = file:read(64) or ""
        file:seek("set", math.max(size - 64, 0))
        tail = file:read(64) or ""
        file:seek("set", math.floor(size / 2))
        mid = file:read(64) or ""
    end

    close_file(file, close_fn)
    return path .. "::" .. size .. "::" .. head .. "::" .. mid .. "::" .. tail
end

local function generate_files_signature(paths)
    local parts = {}
    for _, path in ipairs(paths) do
        parts[#parts + 1] = get_file_signature(path)
    end
    return table.concat(parts, "||")
end

local function is_entry_line(line)
    return trim(line) ~= "" and not line:match("^%s*#")
end

function kaomoji.load_entries(files)
    local entries = {}
    local entries_by_key = {}
    local seen = {}

    for _, file_path in ipairs(files) do
        local file, close_fn = open_data_file(file_path, "r")
        if file then
            for raw_line in file:lines() do
                local line = strip_bom(raw_line)
                if is_entry_line(line) then
                    local key, text = line:match("^([^\t]+)\t(.+)$")
                    key = trim(key)
                    text = trim(text)
                    if key ~= "" and text ~= "" then
                        local uniq = key .. TAB .. text
                        if not seen[uniq] then
                            seen[uniq] = true
                            local entry = { key = key, text = text }
                            entries[#entries + 1] = entry
                            entries_by_key[key] = entries_by_key[key] or {}
                            entries_by_key[key][#entries_by_key[key] + 1] = entry
                        end
                    end
                end
            end
            close_file(file, close_fn)
        end
    end

    return entries, entries_by_key
end

function kaomoji.ensure_entries_loaded(env)
    local signature = generate_files_signature(env.kaomoji_files)
    if kaomoji.entries_signature ~= signature then
        kaomoji.entries, kaomoji.entries_by_key = kaomoji.load_entries(env.kaomoji_files)
        kaomoji.entries_signature = signature
    end
    return kaomoji.entries, kaomoji.entries_by_key
end

local function ensure_main_translator(env)
    if env.kaomoji_main_translator then
        return env.kaomoji_main_translator
    end
    if not (Component and Component.Translator) then
        return nil
    end

    local ok, translator = pcall(function()
        return Component.Translator(env.engine, env.kaomoji_translator_path, env.kaomoji_translator_class)
    end)
    if ok then
        env.kaomoji_main_translator = translator
    end
    return env.kaomoji_main_translator
end

local function build_lookup_segment(query)
    local lookup_seg = Segment(0, #query)
    lookup_seg.tags = Set({ "abc" })
    return lookup_seg
end

local function get_script_text_parts(ctx)
    local parts = {}
    if not ctx or not ctx.composition or ctx.composition:empty() then
        return parts
    end

    local spans = ctx.composition:spans()
    if not spans then
        return parts
    end

    local count = type(spans.count) == "function" and spans:count() or spans.count
    if count == 0 then
        return parts
    end

    local vertices = type(spans.vertices) == "function" and spans:vertices() or spans.vertices
    if not vertices or #vertices < 2 then
        return parts
    end

    local raw_input = ctx.input or ""
    for i = 1, #vertices - 1 do
        local raw_syllable = raw_input:sub(vertices[i] + 1, vertices[i + 1])
        if raw_syllable and raw_syllable ~= "" then
            raw_syllable = raw_syllable:gsub("['%s]", "")
            if raw_syllable ~= "" then
                parts[#parts + 1] = raw_syllable
            end
        end
    end

    return parts
end

local function split_tone_query(query)
    local clean = {}
    local tones = {}

    for i = 1, #query do
        local char = query:sub(i, i)
        if char == "7" or char == "8" or char == "9" or char == "0" then
            tones[#tones + 1] = char
        else
            clean[#clean + 1] = char
        end
    end

    return table.concat(clean), tones
end

local function compress_tone_runs_keep_last(text)
    return (text:gsub("([7890])([7890]+)", function(_, tail)
        return tail:sub(-1)
    end))
end

local function build_tone_fallback_query(env, tone_filter_seq)
    if #tone_filter_seq == 0 then
        return nil
    end

    local syllables = get_script_text_parts(env.engine.context)
    if #syllables == 0 then
        return nil
    end

    local prefix = env.kaomoji_prefix or ""
    if prefix ~= "" and syllables[1] and syllables[1]:sub(1, #prefix) == prefix then
        syllables[1] = syllables[1]:sub(#prefix + 1)
    end
    if syllables[1] == "" then
        table.remove(syllables, 1)
    end
    if #syllables ~= #tone_filter_seq then
        return nil
    end

    local query_parts = {}
    for i, tone in ipairs(tone_filter_seq) do
        local syllable = syllables[i]
        if not syllable or syllable == "" then
            return nil
        end
        if #syllable > 2 then
            syllable = syllable:sub(1, 2)
        end
        query_parts[#query_parts + 1] = syllable .. tone
    end

    return table.concat(query_parts)
end

local function normalize_lookup_query(env, query)
    if not env.kaomoji_enable_tone_fallback then
        return query
    end

    local normalized = compress_tone_runs_keep_last(query)
    local clean_query, tone_filter_seq = split_tone_query(normalized)
    if clean_query ~= "" then
        return normalized
    end

    local fallback_query = build_tone_fallback_query(env, tone_filter_seq)
    if fallback_query and fallback_query ~= "" then
        return fallback_query
    end
    return normalized
end

local function get_query_info(input, seg, env)
    if not seg:has_tag("kaomoji") then
        return nil
    end

    local prefix = env.kaomoji_prefix
    if not prefix or prefix == "" then
        return nil
    end
    if input:sub(1, #prefix) ~= prefix then
        return nil
    end

    local query = input:sub(#prefix + 1)
    for i = 1, #query do
        if not is_valid_query_char(query:sub(i, i), env.kaomoji_allowed_chars) then
            return nil
        end
    end

    return {
        raw_input = input,
        prefix = prefix,
        query = query:lower(),
    }
end

local function query_main_translation(env, query)
    local translator = ensure_main_translator(env)
    if not translator then
        return nil
    end

    local lookup_query = normalize_lookup_query(env, query)
    local ok, translation = pcall(function()
        return translator:query(lookup_query, build_lookup_segment(lookup_query))
    end)
    if not ok then
        return nil
    end
    return translation
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

local function apply_tone_preedit(env, preedit)
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

local function build_candidate(seg, match, yielded, env)
    local cand = Candidate("kaomoji", seg.start, seg._end, match.text, match.comment or "")
    cand.quality = 1000000 - yielded
    -- 保留 /km 前缀，不让提示词在候选 preedit 中消失。
    cand.preedit = apply_tone_preedit(env, match.preedit)
    return cand
end

local function collect_all_entries(env, raw_input)
    local entries = kaomoji.ensure_entries_loaded(env)
    local matched = {}
    local seen = {}

    for _, entry in ipairs(entries) do
        if not seen[entry.text] then
            seen[entry.text] = true
            matched[#matched + 1] = {
                text = entry.text,
                comment = entry.key,
                preedit = raw_input,
            }
        end
    end

    return matched
end

local function collect_matches_once(env, query, raw_input)
    local _, entries_by_key = kaomoji.ensure_entries_loaded(env)
    local translation = query_main_translation(env, query)
    if not translation then
        return {}
    end

    local matched = {}
    local seen = {}

    for main_cand in translation:iter() do
        local group = entries_by_key[main_cand.text]
        if group then
            for _, entry in ipairs(group) do
                if not seen[entry.text] then
                    seen[entry.text] = true
                    matched[#matched + 1] = {
                        text = entry.text,
                        comment = entry.key,
                        preedit = raw_input,
                    }
                    if #matched >= DEFAULT_MAX_CANDIDATES then
                        return matched
                    end
                end
            end
        end
    end

    return matched
end

local function collect_matches_from_translation(env, query, raw_input)
    local fallback_query = query

    while true do
        if fallback_query == "" then
            return collect_all_entries(env, raw_input)
        end

        local matched = collect_matches_once(env, fallback_query, raw_input)
        if #matched > 0 then
            return matched
        end
        fallback_query = fallback_query:sub(1, #fallback_query - 1)
    end
end

function kaomoji.init(env)
    local config = env.engine.schema.config
    env.kaomoji_prefix = get_query_prefix(config)
    env.kaomoji_files = get_kaomoji_files(config)
    env.kaomoji_allowed_chars = get_allowed_query_chars(config)
    env.kaomoji_translator_path, env.kaomoji_translator_class = get_translator_path(config)
    env.kaomoji_enable_tone_fallback = get_config_bool(config, "super_processor/enable_tone_fallback", true)

    kaomoji.ensure_entries_loaded(env)
end

function kaomoji.func(input, seg, env)
    local info = get_query_info(input, seg, env)
    if info == nil then
        return
    end

    local matches
    if info.query == "" then
        matches = collect_all_entries(env, info.raw_input)
    else
        matches = collect_matches_from_translation(env, info.query, info.raw_input)
    end

    local yielded = 0
    for _, match in ipairs(matches) do
        yield(build_candidate(seg, match, yielded, env))
        yielded = yielded + 1
        if yielded >= DEFAULT_MAX_CANDIDATES then
            return
        end
    end
end

return kaomoji
