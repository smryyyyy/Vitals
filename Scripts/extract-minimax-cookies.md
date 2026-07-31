# Vitals MiniMax Cookie Extractor

Chrome 控制台脚本 — 在 `https://platform.minimaxi.com/*` 页面跑。

## ⚠️ 重要说明

**HttpOnly cookie 拿不到** — 这是浏览器安全机制。`_token` 和 `HERTZ-SESSION` 是 HttpOnly，**JS 无法直接读取**。

`cookieStore.getAll()` API 规范上**应该**返回 HttpOnly（草案中），但 Chrome 当前实现**不返回**。

## 🚀 实际可用方法（按优先级）

### 1. Copy as cURL（最稳）
1. F12 → Network 标签
2. 找 `www.minimaxi.com` 开头的请求
3. 右键 → Copy → Copy as cURL (bash)
4. 整段贴给颜颜

### 2. Application → Cookies（手动）
1. F12 → Application 标签
2. Storage → Cookies → `https://www.minimaxi.com`
3. 找 `_token`, `HERTZ-SESSION`, `minimax_group_id_v2`
4. 复制 Value 列

## 📜 Bookmarklet（保存为书签）

虽然 HttpOnly 拿不到，但能**列出**所有可见的 cookie —— 至少能确认 cookie 名是否在:

```javascript
javascript:void(async()=>{const want=["_token","HERTZ-SESSION","minimax_group_id_v2"];const out={};if(window.cookieStore){try{const all=await cookieStore.getAll();for(const c of all)if(want.includes(c.name))out[c.name]=c.value;}catch(e){}}if(!out._token||!out["HERTZ-SESSION"]){for(const c of document.cookie.split("; ")){const[k,v]=c.split("=");if(want.includes(k)&&!out[k])out[k]=v}}console.log("===== 找到的 cookie =====");for(const k of want)console.log(k+": "+(out[k]||"❌ 没找到 (HttpOnly?)"));if(!out._token||!out["HERTZ-SESSION"])console.log("\n用 Copy as cURL 或 Application 拿 HttpOnly cookie");})();
```

## 📂 文件

- `Scripts/extract-minimax-cookies.js` — 完整脚本（带说明）
- 主人也可以直接复制下面这段到 Console:

```javascript
(async function() {
  const want = ["_token", "HERTZ-SESSION", "minimax_group_id_v2"];
  const out = {};
  if (window.cookieStore) {
    try {
      const all = await cookieStore.getAll();
      for (const c of all) if (want.includes(c.name)) out[c.name] = c.value;
    } catch (e) {}
  }
  if (!out._token || !out["HERTZ-SESSION"]) {
    for (const c of document.cookie.split("; ")) {
      const [k, v] = c.split("=");
      if (want.includes(k) && !out[k]) out[k] = v;
    }
  }
  console.log("===== 找到的 cookie =====");
  for (const k of want) console.log(k + ": " + (out[k] || "❌ 没找到 (HttpOnly?)"));
  if (!out._token || !out["HERTZ-SESSION"]) {
    console.log("\n📌 HttpOnly cookie 拿不到, 改用:");
    console.log("  • F12 → Network → Copy as cURL");
    console.log("  • F12 → Application → Cookies → https://www.minimaxi.com");
  }
})();
```
