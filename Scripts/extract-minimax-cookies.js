// Vitals MiniMax cookie 自动抓取脚本
// 用法:
// 1. Chrome 打开 https://platform.minimaxi.com/console/personal-info (登录后任意页)
// 2. F12 → Console 标签
// 3. 粘贴下面整段,回车
// 4. Console 会自动打印 3 个 cookie, 复制到 Vitals 设置面板

(async function() {
  // 触发一个 minimaxi 后端请求, Response headers 里会回传 Set-Cookie (虽然 HttpOnly 浏览器不会写回 cookieStore)
  // 但我们能利用 fetch API 的 credentials:'include' + 主动发请求, 通过 response.headers 看不到
  //
  // 真正可靠的方法: 用 Performance Observer 抓之前已发请求的 Cookie header?
  // 不行, 浏览器不暴露给 JS.
  //
  // 唯一 JS 拿得到 HttpOnly cookie 的途径: cookieStore API (Chrome 87+)
  // 但 Chrome 实测 cookieStore.getAll() 也不返回 HttpOnly (这是规范)

  const want = ["_token", "HERTZ-SESSION", "minimax_group_id_v2"];
  const out = {};

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
  if (!out["_token"] || !out["HERTZ-SESSION"]) {
    for (const c of document.cookie.split("; ")) {
      const [k, v] = c.split("=");
      if (want.includes(k) && !out[k]) out[k] = v;
    }
  }

  console.log("\n========== 复制下面 3 行到 Vitals MiniMax 设置 ==========");
  let missing = false;
  for (const k of want) {
    if (out[k]) {
      console.log(k + " = " + out[k]);
    } else {
      console.warn("⚠️  拿不到 " + k + " (可能是 HttpOnly, JS 读不到)");
      missing = true;
    }
  }
  console.log("========================================================\n");

  if (missing) {
    console.log("📌 拿不到 HttpOnly cookie 的备用方法:");
    console.log("");
    console.log("  方法 A (Copy as cURL):");
    console.log("    1. F12 → Network 标签");
    console.log("    2. 找 www.minimaxi.com 开头的请求");
    console.log("    3. 右键 → Copy → Copy as cURL (bash)");
    console.log("    4. 整段贴给我 (颜颜), 我来解析");
    console.log("");
    console.log("  方法 B (Application):");
    console.log("    1. F12 → Application 标签");
    console.log("    2. Storage → Cookies → https://www.minimaxi.com");
    console.log("    3. 找 _token, HERTZ-SESSION, minimax_group_id_v2");
    console.log("    4. 复制 Value 列");
  } else {
    console.log("✅ 全部抓到! 直接复制到 Vitals 即可.");
  }

  return out;
})();
