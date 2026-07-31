// Vitals MiniMax cookie extractor
// 用法: 在 platform.minimaxi.com/console/personal-info 页面
//       F12 → Console → 粘贴此脚本 → 回车
//
// ⚠️ 重要: _token 和 HERTZ-SESSION 是 HttpOnly cookie,
//    JS 拿不到! 这个脚本只能列出可见的 cookie (如 minimax_group_id_v2)
//
// 拿 HttpOnly 的真实办法:
//   1. F12 → Network → 找 www.minimaxi.com 请求 → Copy as cURL (bash)
//   2. F12 → Application → Cookies → https://www.minimaxi.com

(async function() {
  const want = ["_token", "HERTZ-SESSION", "minimax_group_id_v2"];
  const out = {};

  // 优先: cookieStore (Chrome 87+)
  if (window.cookieStore) {
    try {
      const all = await cookieStore.getAll();
      for (const c of all) {
        if (want.includes(c.name)) out[c.name] = c.value;
      }
    } catch (e) {
      console.error("cookieStore.getAll() 失败:", e);
    }
  }

  // 兜底: document.cookie (只能拿非 HttpOnly)
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
      // 只显示前 20 字符, 完整值仍可读
      console.log(k + ": " + out[k].substring(0, 20) + "...");
    } else {
      console.warn("❌ " + k + " 拿不到 (HttpOnly?)");
    }
  }

  if (!out._token || !out["HERTZ-SESSION"]) {
    console.log("\n📌 HttpOnly cookie 拿不到, 改用:");
    console.log("  1. F12 → Network → Copy as cURL (bash) → 贴给颜颜");
    console.log("  2. F12 → Application → Cookies → www.minimaxi.com");
  } else {
    console.log("\n✅ 全部抓到!");
  }

  return out;
})();
