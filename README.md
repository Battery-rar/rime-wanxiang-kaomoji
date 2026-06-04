# Wanxiang-Kaomoji

一个为万象输入法提供颜文字快捷输入功能的扩展词库。

通过 /km 前缀快速输入各类颜文字。

## 功能特性

- /km + 拼音 快速输入颜文字
- 按照拼音输入相应的颜文字
- 专为万象输入法制作
- 可在kaomoji_user.txt中扩展

## 效果展示

| 输入 | 输出示例 |
|--------|--------|
| /kmai | (♡˙︶˙♡) |
| /kmaa | Ｏ(≧口≦)Ｏ |
| /kmkaixin | (≧▽≦) |
| /kmdaku | QAQ |
| /kmwu | =_= |

> 实际词条以仓库内容为准。

## 安装方法

将kaomoji.lua放在Rime/lua/wanxiang/下

将kaomoji.txt以及kaomoji_user.txt放在Rime/lua/data/下

修改wanxiang.custom.yaml，如下

```yaml
patch:
  kaomoji:
    files:
      - lua/data/kaomoji.txt       # 默认文件
      #- lua/data/kaomoji_user.txt  # 用户自定义文件，要用的解除注释即可

  engine/translators/+:
    - lua_translator@*wanxiang.kaomoji
    
  recognizer/patterns/+:
    kaomoji: "^/km[A-Za-z7890]*$"  #前缀可以在这里配置，如果需要双拼的话正则应该也在这修改（AI说的QAQ）
```
      

## 自定义

你可以直接编辑词库文件添加新的颜文字

由于这是一个第三方项目，其实你在哪里配置都一样

```text
开心  (≧▽≦)
震惊  Σ(っ °Д °;)っ
哭  (T_T)
  ...
```

保存后重新部署即可生效。

## 贡献
## Contributors

### Not a Human

<a href="https://github.com/Battery-rar/rime-wanxiang-kaomoji/graphs/contributors">

  <img src="https://contrib.rocks/image?repo=Battery-rar/rime-wanxiang-kaomoji" width="50"/>

</a>


### Cat

<a href="https://github.com/deemoe404">

  <img src="https://github.com/deemoe404.png" width="50"/>

</a>


### AI

  ChatGPT 5.4
  
  Codex



## License

MIT License
