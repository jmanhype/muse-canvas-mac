/* muse-canvas-mac: English overlay for the MuseCanvas canvas UI.
 *
 * The upstream app ships a partial en-US locale: navigation and settings
 * are translated, but the homepage cards, the Agent panel, and category
 * labels fall back to Chinese. This overlay runs in the browser (appended
 * to web/config.js by `muse english on`) and fills those gaps at runtime
 * with exact-phrase translation — it never touches the integrity-managed
 * app bundle, never translates user content (prompts, template text,
 * author names), and `muse english off` restores the pristine config.js.
 */
(function () {
  "use strict";
  if (window.__museEnglishOverlay) return;
  window.__museEnglishOverlay = true;

  // Exact-match map on the *full trimmed* text of a node, so a short word
  // like 自动 only matches a node that is exactly that word — never a word
  // inside a longer prompt body.
  var PHRASES = {
    // -- homepage: account pool panel ---------------------------------
    "账号流量池": "Account traffic pool",
    "账号越多，跑得越快——加账号，就是加速度、加产能": "More accounts, faster runs — adding accounts adds speed and capacity",
    "单账号并发": "concurrent tasks per account",
    "自动": "automatic",
    "分流不排队": "routing, no queueing",
    "后台补取": "background auto-fetch",
    // -- homepage: feature cards -------------------------------------
    "并行生成": "Parallel generation",
    "一个账号同时跑 5 个任务，图片、视频、文字一起出，不用一个个等。": "One account runs 5 tasks at once — images, videos, and text together, no waiting one by one.",
    "自动分流": "Auto routing",
    "多加几个账号，任务自动分到空闲账号——账号越多，产能越大。": "Add more accounts and tasks route to idle ones automatically — more accounts, more capacity.",
    "自动补取": "Auto retry & fetch",
    "视频做好但一时取不回，后台自动补取并填回画布，不用重做。": "If a video finishes but can't be fetched right away, the background fetches it and fills it into the canvas — no redo needed.",
    "一页看清": "See it all on one page",
    "账号状态、剩余额度、任务记录都在一页，过期一键重新导入。": "Account status, remaining quota, and task history on one page; re-import expired accounts in one click.",
    // -- homepage: CTAs & footer --------------------------------------
    "打开流量池 · 加账号": "Open traffic pool · add accounts",
    "🌀 Muse 账号 · 邀请 · 额度": "🌀 Muse account · invite · quota",
    "官网 · 新版下载": "Official site · latest download",
    "螺旋通天屁 出品 · 新版下载和联系方式：ai.fylmlgsb.xyz": "Made by 螺旋通天屁 · downloads & contact: ai.fylmlgsb.xyz",
    "开始使用": "Get started",
    "沉淀每一次好结果": "Bank every good result",
    "收藏稳定出图的提示词、参考风格和结果图片，让下一次创作从已有经验开始。": "Save prompts, reference styles, and result images that work reliably, so your next creation starts from experience.",
    "查看提示词库": "Browse the prompt library",
    // -- announcement banner (current vendor notice; future ones are
    //    vendor content and stay as-is) --------------------------------
    "Mac 测试版已修复 Claude 登录闪退的问题。如果你用的是今天早些时候下载的版本，请到官网重新下载最新版 Mac 安装包，覆盖安装即可，数据会保留；刚下载的请忽略本条。": "Mac beta: the Claude login crash is fixed. If you downloaded earlier today, re-download the latest Mac installer from the official site and install over it — your data is kept. If you just downloaded, ignore this.",
    "查 看": "View",
    "关闭": "Close",
    // -- Agent panel ----------------------------------------------------
    "模型：": "Model:",
    "模型": "Model",
    "请选择 AI 模型": "Select an AI model",
    "历史": "History",
    "切换 / 添加模型": "Switch / add model",
    "本地 Claude 可读写当前打开的画布：写剧本、建节点、改提示词、发起生成。用哪个模型，点上面「切换 / 添加模型」。": "Local Claude can read and write the open canvas: write scripts, create nodes, edit prompts, and start generations. To pick a model, click “Switch / add model” above.",
    "想让 Claude 处理某个节点：先在画布上点选它，再发消息": "To have Claude work on a node: click to select it on the canvas first, then send your message",
    "跟 Claude 说要做什么（Enter 发送，Shift+Enter 换行）": "Tell Claude what to do (Enter to send, Shift+Enter for a new line)",
    "请先选择接口": "Select a provider first",
    "思考": "Thinking",
    "默认": "Default",
    "新对话": "New chat",
    "发送": "Send",
    "语音输入": "Voice input",
    "Claude 模型": "Claude model",
    "Claude 思考强度": "Claude thinking level",
    "当前接口的思考方式由服务商决定": "Thinking behavior for this provider is decided by the provider",
    // -- provider names -------------------------------------------------
    "Muse 本机生成池": "Muse local generation pool",
    "muse-image（Muse 本机生成池）": "muse-image (Muse local generation pool)",
    "muse-video（Muse 本机生成池）": "muse-video (Muse local generation pool)",
    // -- image/video studio categories ----------------------------------
    "旅游": "Travel", "封面": "Cover", "滤镜": "Filters", "想象": "Imagination",
    "穿搭": "Outfit", "电商": "E-commerce", "插画": "Illustration",
    "装修": "Interior", "头像": "Avatar", "漫画": "Comics", "解构": "Deconstruct",
    "类脑": "Brain-like", "广告设计": "Ad design", "人像/角色": "Portrait / character",
    "3D/手办/潮玩": "3D / figures / designer toys", "需要参考图": "Reference image needed",
    "风景/场景": "Landscape / scene", "3D渲染/材质": "3D render / materials",
    "创意转换": "Creative transform", "产品展示图": "Product shots",
    "动漫/插画": "Anime / illustration", "文字渲染": "Text rendering",
    "海报设计": "Poster design", "AI卡牌": "AI trading cards",
    "食物摄影": "Food photography", "Logo设计": "Logo design",
    "UI与界面": "UI & interfaces", "建筑/空间": "Architecture / space",
    "插画/艺术": "Illustration / art", "信息图设计": "Infographic design",
    "场景/叙事": "Scene / narrative", "摄影": "Photography", "其他": "Other",
    "古风/历史": "Historical", "文档设计": "Document design",
    "角色肖像": "Character portrait",
    // -- template groups --------------------------------------------------
    "图像模板 - 信息图表": "Image template · infographic",
    "图像模板 - 动漫插画": "Image template · anime illustration",
    "图像模板 - 产品海报": "Image template · product poster",
    "图像模板 - 游戏截图/UI": "Image template · game UI",
    "图像模板 - 插画地图": "Image template · illustrated map",
    "图像模板 - 头像肖像": "Image template · avatar portrait",
    "图像模板 - 社交媒体海报": "Image template · social poster",
    "视频模板 - 动画": "Video template · animation",
    "视频模板 - 广告/品牌": "Video template · ads / branding",
    "视频模板 - 武侠/历史": "Video template · wuxia / historical",
    "视频模板 - 舞蹈/动作": "Video template · dance / action",
    "视频模板 - 短视频/影像": "Video template · short-form video",
    "视频模板 - 电影叙事": "Video template · cinematic narrative",
    "视频模板 - 游戏/科幻": "Video template · game / sci-fi",
    "视频模板 - 特效/奇幻": "Video template · VFX / fantasy",
    "视频模板 - 动漫改编": "Video template · anime adaptation",
    "视频模板 - 社交/舞蹈": "Video template · social / dance",
    // -- prompt library group headers (labels, not content) --------------
    "社交媒体帖子": "Social media posts", "个人资料 / 头像": "Profile / avatar",
    "信息图 / 教育视觉图": "Infographics / educational visuals",
    "YouTube 缩略图": "YouTube thumbnails", "漫画 / 故事板": "Comics / storyboards",
    "产品营销": "Product marketing", "电商主图": "E-commerce hero images",
    "游戏素材": "Game assets",
    "摄影与照片级写实": "Photography & photorealism",
    "游戏与娱乐": "Games & entertainment", "UI / UX 与社交媒体": "UI / UX & social media",
    "视频、动画与拼贴": "Video, animation & collage",
    "字体排版与海报设计": "Typography & poster design",
    "信息图、教育与文档": "Infographics, education & docs",
    "角色与一致性": "Characters & consistency",
    "图像编辑与风格迁移": "Image editing & style transfer",
    "旅行手账图": "Travel journal page"
  };

  // Templated strings (numbers etc.).
  var PATTERNS = [
    [/^(\d+(?:\.\d+)?)\s*个$/, "$1"]
  ];

  var SKIP_TAGS = { SCRIPT: 1, STYLE: 1, CODE: 1, PRE: 1, TEXTAREA: 1, NOSCRIPT: 1 };

  function convert(text) {
    var t = text.trim();
    if (!t) return null;
    if (!/[\u4e00-\u9fff]/.test(t)) return null;
    if (PHRASES.hasOwnProperty(t)) return PHRASES[t];
    for (var i = 0; i < PATTERNS.length; i++) {
      var m = t.match(PATTERNS[i][0]);
      if (m) return t.replace(PATTERNS[i][0], PATTERNS[i][1]);
    }
    return null;
  }

  function pad(original, replacement) {
    var lead = original.match(/^\s*/)[0];
    var trail = original.match(/\s*$/)[0];
    return lead + replacement + trail;
  }

  function translateTextNode(node) {
    var parent = node.parentNode;
    if (!parent) return;
    var name = parent.nodeName;
    if (SKIP_TAGS[name]) return;
    var out = convert(node.nodeValue);
    if (out !== null) node.nodeValue = pad(node.nodeValue, out);
  }

  var ATTRS = ["placeholder", "aria-label", "title"];
  function translateElement(el) {
    if (!el.getAttribute) return;
    for (var i = 0; i < ATTRS.length; i++) {
      var a = ATTRS[i];
      var v = el.getAttribute(a);
      if (!v) continue;
      var out = convert(v);
      if (out !== null && out !== v) el.setAttribute(a, out);
    }
  }

  function walk(root) {
    try {
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) translateTextNode(walker.currentNode);
      if (root.querySelectorAll) {
        var els = root.querySelectorAll("[placeholder],[aria-label],[title]");
        for (var i = 0; i < els.length; i++) translateElement(els[i]);
      }
    } catch (e) { /* never break the host app */ }
  }

  function start() {
    if (!document.body) { setTimeout(start, 50); return; }
    walk(document.body);
    var observer = new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var m = mutations[i];
        if (m.type === "characterData") translateTextNode(m.target);
        else if (m.type === "childList") {
          for (var j = 0; j < m.addedNodes.length; j++) {
            var n = m.addedNodes[j];
            if (n.nodeType === Node.TEXT_NODE) translateTextNode(n);
            else if (n.nodeType === Node.ELEMENT_NODE) walk(n);
          }
        } else if (m.type === "attributes") {
          translateElement(m.target);
        }
      }
    });
    observer.observe(document.body, {
      childList: true, subtree: true, characterData: true,
      attributes: true, attributeFilter: ATTRS
    });
  }

  start();
})();
