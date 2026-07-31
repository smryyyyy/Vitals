# Vitals MiniMax Cookie 提取工具

> ⚠️ **重要前提**: `_token` 和 `HERTZ-SESSION` 是 **HttpOnly** cookie — 浏览器的安全机制决定了 **JavaScript 拿不到**。这个脚本只能列出**非 HttpOnly** 的 cookie（如 `minimax_group_id_v2`）。

## 🎯 拿 HttpOnly cookie 的真实方法

### 方法 A：Copy as cURL (推荐，10 秒)

```
1. Chrome 打开 platform.minimaxi.com 并登录
2. F12 → Network 标签
3. 触发任意请求 (刷新页面即可)
4. 找 www.minimaxi.com 开头的请求
5. 右键 → Copy → Copy as cURL (bash)
6. 整段命令行贴给颜颜
```

cURL 命令里的 `-H 'Cookie: _token=eyJ...; HERTZ-SESSION=...; minimax_group_id_v2=...'` 这部分就是完整 cookie。

### 方法 B：Application 面板 (30 秒)

```
1. F12 → Application 标签
2. 左边 → Storage → Cookies → https://www.minimaxi.com
3. 找 _token, HERTZ-SESSION, minimax_group_id_v2
4. 复制 Value 列
```

HttpOnly cookie 在 Application 面板里**也能看到**完整 Value。

## 📜 控制台脚本 (Scripts/extract-minimax-cookies.js)

```javascript
(async function() {
  const want = ["_token", "HERTZ-SESSION", "minimax_group_id_v2"];
  const out = {};
  if (window.cookieStore) {
    try {
      const all = await cookieStore.getAll();
      for (const c of all) {
        if (want.includes(c.name)) out[c.name] = c.value;
      }
    } catch (e) {}
  }
  if (!out._token || !out["HERTZ-SESSION"]) {
    for (const c of document.cookie.split("; ")) {
      const idx = c.indexOf("=");
      if (idx < 0) continue;
      const k = c.substring(0, idx);
      const v = c.substring(idx + 1);
      if (want.includes(k) && !out[k]) out[k] = v;
    }
  }
  console.log("\n===== 找到的 cookie =====");
  for (const k of want) {
    if (out[k]) {
      console.log(k + ": " + out[k].substring(0, 20) + "...");
    } else {
      console.warn("❌ " + k + " 拿不到 (HttpOnly?)");
    }
  }
  if (!out._token || !out["HERTZ-SESSION"]) {
    console.log("\n📌 HttpOnly 拿不到, 改用 Copy as cURL 或 Application 面板");
  } else {
    console.log("\n✅ 全部抓到!");
  }
  return out;
})();
```

## 🔖 Bookmarklet (保存为书签)

```javascript
javascript:void(async()=>{const want=["_token","HERTZ-SESSION","minimax_group_id_v2"];const out={};if(window.cookieStore){try{const all=await cookieStore.getAll();for(const c of all)if(want.includes(c.name))out[c.name]=c.value;}catch(e){}}if(!out._token||!out["HERTZ-SESSION"]){for(const c of document.cookie.split("; ")){const i=c.indexOf("=");if(i<0)continue;const k=c.substring(0,i),v=c.substring(i+1);if(want.includes(k)&&!out[k])out[k]=v}}console.log("===== MiniMax cookie =====");for(const k of want)console.log(k+": "+(out[k]?out[k].substring(0,20)+"...":"❌ HttpOnly"));if(!out._token||!out["HERTZ-SESSION"])console.log("用 Copy as cURL 或 Application 拿 HttpOnly")})();
```

**保存为书签的方法**:
1. 右键书签栏 → 添加书签
2. 名字: `Vitals MiniMax Cookie`
3. URL: 上面那段
4. 在 platform.minimaxi.com 页面点这个书签 → Console 显示结果

## 📊 Cookie 有效期

| Cookie | 过期时间 | 备注 |
|---|---|---|
| `_token` (JWT) | ~39 天 (约 2026-09-07) | JWT 格式 `eyJ...` |
| `HERTZ-SESSION` | ~30 天 (约 2026-08-28) | **最先过期** |
| `minimax_group_id_v2` | 1 年 | 通常不会过期 |

## ⚠️ 安全提醒

- Cookie **不要** commit 到 git
- 不要发到群里、邮件、IM
- 建议**过期前**定期更换（避免账号被风控）
