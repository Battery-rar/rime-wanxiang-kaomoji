-- 万象家族 lua，颜文字输入模块
-- 采用 txt 维护数据，支持词典补全与 userdb 持久化缓存
-- 通过 recognizer/patterns/kaomoji 进入
-- 配置示例：
-- kaomoji:
--   db_name: "lua/kaomoji"  # 可选，缓存数据库名称/路径，默认值为 "lua/kaomoji"
--   files:                  # 可选，自定义数据文件列表
--     - lua/data/kaomoji.txt

local wanxiang = require("wanxiang/wanxiang")
local userdb = require("wanxiang/userdb")

local DEFAULT_DB_NAME = "lua/kaomoji"
local DEFAULT_MAX_CANDIDATES = 80
local DEFAULT_DATA_FILES = {
    "lua/data/kaomoji.txt",
    "lua/data/kaomoji_user.txt",
}
local DEFAULT_DICT_PATHS = {
    "dicts/jichu.dict.yaml",
    "dicts/zi.dict.yaml",
    "dicts/diming.dict.yaml",
    "dicts/duoyin.dict.yaml",
    "dicts/lianxiang.dict.yaml",
    "dicts/shici.dict.yaml",
    "dicts/huaxue.dict.yaml",
    "dicts/yaopin.dict.yaml",
    "dicts/yixue.dict.yaml",
    "dicts/cn&en.dict.yaml",
}
local BOM = string.char(239, 187, 191)
local TAB = "\t"
local ENTRY_KEY_PREFIX = "entry/"

local TONE_MAP = {
    ["ā"] = "a", ["á"] = "a", ["ǎ"] = "a", ["à"] = "a",
    ["ē"] = "e", ["é"] = "e", ["ě"] = "e", ["è"] = "e",
    ["ī"] = "i", ["í"] = "i", ["ǐ"] = "i", ["ì"] = "i",
    ["ō"] = "o", ["ó"] = "o", ["ǒ"] = "o", ["ò"] = "o",
    ["ū"] = "u", ["ú"] = "u", ["ǔ"] = "u", ["ù"] = "u",
    ["ǖ"] = "v", ["ǘ"] = "v", ["ǚ"] = "v", ["ǜ"] = "v", ["ü"] = "v",
    ["ń"] = "n", ["ň"] = "n", ["ǹ"] = "n",
    ["ḿ"] = "m",
}

local META_KEY = {
    version = "wanxiang_version",
    files_sig = "files_signature",
    dict_sig = "dict_signature",
}

local kaomoji = {
    files_signature = nil,
    dict_signature = nil,
    entries = {},
    db_name = nil,
    db = nil,
    db_mode = nil,
}

local function trim(text)
    return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_search_code(text)
    return trim((text or ""):lower():gsub("[^a-z]", ""))
end

local function strip_bom(text)
    if not text then return "" end
    return text:gsub("^" .. BOM, "")
end

local function is_absolute_path(path)
    if not path then return false end
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
    if not path or path == "" then return nil end
    if is_absolute_path(path) then
        return io.open(path, mode or "r")
    end
    return wanxiang.load_file_with_fallback(path, mode)
end

local function get_config_list(config, path)
    local values = {}
    local list = config:get_list(path)
    if list then
        for i = 0, list.size - 1 do
            local item = list:get_value_at(i)
            local value = item and trim(item.value) or ""
            if value ~= "" then
                table.insert(values, value)
            end
        end
    end
    return values
end

local function get_configured_files(config)
    local files = get_config_list(config, "kaomoji/files")
    return #files > 0 and files or DEFAULT_DATA_FILES
end

local function get_dict_files()
    local files = {}
    for _, path in ipairs(DEFAULT_DICT_PATHS) do
        if wanxiang.get_filename_with_fallback(path) then
            table.insert(files, path)
        end
    end
    return files
end

local function for_each_file_line(paths, handler)
    for _, file_path in ipairs(paths) do
        local file, close_fn = open_data_file(file_path, "r")
        if file then
            for raw_line in file:lines() do
                handler(raw_line, file_path)
            end
            close_file(file, close_fn)
        end
    end
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

-- 轻量文件指纹：文件内容变化时才重新建立索引
local function generate_files_signature(paths)
    local sig_parts = {}
    for _, path in ipairs(paths) do
        table.insert(sig_parts, get_file_signature(path))
    end
    return table.concat(sig_parts, "||")
end

-- 拼音归一化：统一转小写、去声调、过滤非字母字符
local function normalize_pinyin(text)
    text = trim(text)
    if text == "" then return "" end

    for tone, plain in pairs(TONE_MAP) do
        text = text:gsub(tone, plain)
    end

    return text:lower()
        :gsub("[^a-z%s]", " ")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function build_initials(syllables)
    local initials = {}
    for _, syllable in ipairs(syllables) do
        initials[#initials + 1] = syllable:sub(1, 1)
    end
    return table.concat(initials, "")
end

local function project_syllables(projection, syllables)
    if not projection then return nil end

    local projected = {}
    local has_change = false
    for _, syllable in ipairs(syllables) do
        local projected_syllable = normalize_search_code(projection:apply(syllable, true))
        if projected_syllable == "" then
            projected_syllable = syllable
        elseif projected_syllable ~= syllable then
            has_change = true
        end
        projected[#projected + 1] = projected_syllable
    end

    return has_change and projected or nil
end

-- 为一个候选补充可检索编码：全拼 / 首字母 / algebra 投影结果
local function add_search_form(entry, form)
    form = trim(form)
    if form == "" or entry.form_seen[form] then return end
    entry.form_seen[form] = true
    table.insert(entry.forms, form)
end

local function add_code_form(entry, form)
    add_search_form(entry, normalize_search_code(form))
end

local function add_pinyin_phrase(entry, raw_pinyin, projection)
    local normalized = normalize_pinyin(raw_pinyin)
    if normalized == "" then return end

    local syllables = {}
    for syllable in normalized:gmatch("%S+") do
        table.insert(syllables, syllable)
    end
    if #syllables == 0 then return end

    add_code_form(entry, table.concat(syllables, ""))
    add_code_form(entry, build_initials(syllables))

    local projected_syllables = project_syllables(projection, syllables)
    if projected_syllables then
        add_code_form(entry, table.concat(projected_syllables, ""))
        add_code_form(entry, build_initials(projected_syllables))
    end
end

local function reset_entry_forms(entries)
    for _, entry in ipairs(entries) do
        entry.forms = {}
        entry.form_seen = {}
    end
end

local function get_entry_db_key(entry)
    return ENTRY_KEY_PREFIX .. entry.key .. TAB .. entry.text
end

local function new_entry(key, text)
    return {
        key = key,
        text = text,
        ascii_key = key:lower(),
        forms = {},
        form_seen = {},
    }
end

local function is_entry_line(line)
    return trim(line) ~= "" and not line:match("^%s*#")
end

-- 从 txt 加载基础数据
-- 格式：关键词 [tab] 颜文字
function kaomoji.load_entries(files)
    local entries = {}
    local seen = {}

    for_each_file_line(files, function(raw_line)
        local line = strip_bom(raw_line)
        if is_entry_line(line) then
            local key, text = line:match("^([^\t]+)\t(.+)$")
            key = trim(key)
            text = trim(text)
            if key ~= "" and text ~= "" then
                local uniq = key .. TAB .. text
                if not seen[uniq] then
                    seen[uniq] = true
                    table.insert(entries, new_entry(key, text))
                end
            end
        end
    end)

    return entries
end

-- 用万象现有词典补齐拼音，兼容只写“关键词 + 颜文字”的简洁格式
function kaomoji.enrich_entries(entries, dict_files, projection)
    local wanted = {}
    for _, entry in ipairs(entries) do
        wanted[entry.key] = wanted[entry.key] or {}
        table.insert(wanted[entry.key], entry)
    end

    for_each_file_line(dict_files, function(raw_line)
        local line = strip_bom(raw_line)
        local word, pinyin = line:match("^([^\t]+)\t([^\t]+)")
        local matched = word and wanted[word]
        if matched and pinyin and pinyin ~= "" then
            for _, entry in ipairs(matched) do
                add_pinyin_phrase(entry, pinyin, projection)
            end
        end
    end)
end

local function set_db_mode(db, writable)
    local mode = writable and "rw" or "ro"
    if kaomoji.db_mode == mode then return db end

    if kaomoji.db_mode then
        db:close()
    end
    if writable then
        db:open()
    else
        db:open_read_only()
    end
    kaomoji.db_mode = mode
    return db
end

local function is_db_cache_valid(db, files_sig, dict_sig)
    return db
        and db:meta_fetch(META_KEY.version) == wanxiang.version
        and (db:meta_fetch(META_KEY.files_sig) or "") == files_sig
        and (db:meta_fetch(META_KEY.dict_sig) or "") == dict_sig
end

local function load_entry_forms(raw, entry)
    if raw and raw ~= "" then
        for form in raw:gmatch("[^\t]+") do
            add_search_form(entry, form)
        end
    end
end

local function get_dict_signature(dict_files)
    return table.concat(dict_files, "\n") .. "::" .. generate_files_signature(dict_files)
end

local function clear_db(db)
    local clear = db["clear"]
    if clear then
        clear(db)
    elseif db.empty then
        db:empty(true)
    end
end

local function is_query_match(forms, query)
    for _, form in ipairs(forms) do
        if form:find(query, 1, true) == 1 then
            return true
        end
    end
    return false
end

local function get_active_entries(env, query)
    if query == "" then
        return kaomoji.ensure_entries_loaded(env)
    end
    return kaomoji.ensure_dict_loaded(env)
end

local function extract_query_prefix(pattern)
    if not pattern or pattern == "" then
        return nil
    end

    local source = pattern
    local prefix = {}
    local started = false
    local escaped = false

    if source:sub(1, 1) == "^" then
        source = source:sub(2)
    end

    for i = 1, #source do
        local char = source:sub(i, i)
        if escaped then
            prefix[#prefix + 1] = char
            started = true
            escaped = false
        elseif char == "\\" then
            escaped = true
        elseif char:match("[%[%]%(%)%*%+%?%$%|%.]") then
            break
        else
            prefix[#prefix + 1] = char
            started = true
        end
    end

    local literal_prefix = table.concat(prefix, "")
    if not started or literal_prefix == "" then return nil end
    return literal_prefix
end

local function get_kaomoji_query(input, seg, env)
    if not seg:has_tag("kaomoji") then
        return nil
    end

    local prefix = env.kmj_prefix
    if not prefix or prefix == "" then return nil end
    if input:sub(1, #prefix) ~= prefix then
        return nil
    end

    local query = input:sub(#prefix + 1):lower()
    if query:find("[^a-z]") then
        return nil
    end
    return query
end

local function get_db_name(config)
    local db_name = config:get_string("kaomoji/db_name") or DEFAULT_DB_NAME
    return db_name ~= "" and db_name or DEFAULT_DB_NAME
end

local function get_query_prefix(config)
    return extract_query_prefix(config:get_string("recognizer/patterns/kaomoji"))
end

local function get_algebra_projection(config)
    local algebra_list = config:get_list("speller/algebra")
    if not algebra_list or algebra_list.size == 0 then
        return nil
    end

    local projection = Projection()
    if projection and projection:load(algebra_list) then
        return projection
    end
    return nil
end

local function build_candidate(seg, entry, yielded)
    local cand = Candidate("kaomoji", seg.start, seg._end, entry.text, entry.key)
    cand.quality = 1000000 - yielded
    return cand
end

local function ensure_db(env, writable)
    if not kaomoji.db or kaomoji.db_name ~= env.kmj_db_name then
        if kaomoji.db and kaomoji.db_mode then
            kaomoji.db:close()
        end
        kaomoji.db_name = env.kmj_db_name
        kaomoji.db = userdb.LevelDb(env.kmj_db_name)
        kaomoji.db_mode = nil
    end

    return set_db_mode(kaomoji.db, writable)
end

local function load_forms_from_db(env, files_sig, dict_sig, entries)
    local db = ensure_db(env, false)
    if not is_db_cache_valid(db, files_sig, dict_sig) then return false end

    reset_entry_forms(entries)
    for _, entry in ipairs(entries) do
        load_entry_forms(db:fetch(get_entry_db_key(entry)), entry)
    end
    return true
end

local function save_forms_to_db(env, files_sig, dict_sig, entries)
    local db = ensure_db(env, true)
    if not db then return end

    clear_db(db)

    for _, entry in ipairs(entries) do
        if #entry.forms > 0 then
            db:update(get_entry_db_key(entry), table.concat(entry.forms, TAB))
        end
    end

    db:meta_update(META_KEY.version, wanxiang.version)
    db:meta_update(META_KEY.files_sig, files_sig)
    db:meta_update(META_KEY.dict_sig, dict_sig)

    db:close()
    db:open_read_only()
    kaomoji.db_mode = "ro"
end

-- 基础缓存：文件内容变化时才重建基础条目，首次 /km 空查询只走这一层
function kaomoji.ensure_entries_loaded(env)
    local files_signature = generate_files_signature(env.kmj_files)
    if kaomoji.files_signature ~= files_signature then
        kaomoji.entries = kaomoji.load_entries(env.kmj_files)
        kaomoji.files_signature = files_signature
        kaomoji.dict_signature = nil
    end

    return kaomoji.entries
end

-- 拼音缓存：只有真正按拼音检索时，才扫描万象词典补齐编码
function kaomoji.ensure_dict_loaded(env)
    kaomoji.ensure_entries_loaded(env)

    local files_sig = kaomoji.files_signature or ""
    local dict_signature = get_dict_signature(env.kmj_dict_files)
    if kaomoji.dict_signature ~= dict_signature then
        if not load_forms_from_db(env, files_sig, dict_signature, kaomoji.entries) then
            reset_entry_forms(kaomoji.entries)
            kaomoji.enrich_entries(kaomoji.entries, env.kmj_dict_files, env.kmj_projection)
            save_forms_to_db(env, files_sig, dict_signature, kaomoji.entries)
        end
        kaomoji.dict_signature = dict_signature
    end

    return kaomoji.entries
end

-- 匹配策略：支持关键词前缀、拼音全拼、首字母与模糊简拼
local function match_entry(entry, query)
    if query == "" or entry.ascii_key:find(query, 1, true) then
        return true
    end
    return is_query_match(entry.forms, query)
end

-- 收集候选：保持原文件顺序，同一颜文字只输出一次
local function collect_matches(env, query)
    local matched = {}
    local seen = {}
    local entries = get_active_entries(env, query)

    for _, entry in ipairs(entries) do
        if match_entry(entry, query) and not seen[entry.text] then
            seen[entry.text] = true
            table.insert(matched, entry)
        end
    end

    return matched
end

-- 初始化：读取配置并预热 userdb 缓存
function kaomoji.init(env)
    local config = env.engine.schema.config

    env.kmj_db_name = get_db_name(config)
    env.kmj_prefix = get_query_prefix(config)
    env.kmj_projection = get_algebra_projection(config)
    env.kmj_files = get_configured_files(config)
    env.kmj_dict_files = get_dict_files()

    kaomoji.ensure_dict_loaded(env)
end

-- translator 主入口：解析 query、生成候选、按排序结果输出
function kaomoji.func(input, seg, env)
    local query = get_kaomoji_query(input, seg, env)
    if query == nil then return end

    local yielded = 0
    for _, entry in ipairs(collect_matches(env, query)) do
        yield(build_candidate(seg, entry, yielded))
        yielded = yielded + 1
        if yielded >= DEFAULT_MAX_CANDIDATES then
            return
        end
    end
end

return kaomoji
