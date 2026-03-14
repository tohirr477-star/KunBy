import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

async function sendTg(chatId: number, text: string) {
  if (!BOT_TOKEN || !chatId) return;
  await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      chat_id: chatId,
      text,
      parse_mode: "HTML",
      reply_markup: {
        inline_keyboard: [[{
          text: "📱 KunByni ochish",
          url: "https://t.me/kunby_bot/app"
        }]]
      }
    })
  });
}

async function getTgId(userId: string): Promise<number | null> {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/users?id=eq.${userId}&select=telegram_id`,
    { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } }
  );
  const rows = await res.json();
  return rows?.[0]?.telegram_id ?? null;
}

async function getUserName(userId: string): Promise<string> {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/users?id=eq.${userId}&select=name`,
    { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } }
  );
  const rows = await res.json();
  return rows?.[0]?.name ?? "Foydalanuvchi";
}

serve(async (req) => {
  try {
    const { type, table, record, old_record } = await req.json();

    if (table === "messages" && type === "INSERT") {
      const toId   = record.to_id;
      const fromId = record.from_id;
      const text   = record.text ?? "";

      const tgId = await getTgId(toId);
      if (!tgId) return new Response("no tg", { status: 200 });

      const senderName = await getUserName(fromId);
      const isOffer = text.startsWith("💼");

      const msg = isOffer
        ? `💼 <b>${senderName}</b> sizga ish taklif qildi!\n\n${text.slice(0, 200)}`
        : `💬 <b>${senderName}</b>:\n${text.slice(0, 200)}`;

      await sendTg(tgId, msg);
    }

    if (table === "jobs" && type === "UPDATE") {
      const newSt  = record.status;
      const oldSt  = old_record?.status;
      if (newSt === oldSt) return new Response("same", { status: 200 });

      const fromId = record.from_id;
      const toId   = record.to_id;
      const title  = record.title ?? "Ish";

      const msgs: Record<string, { to: string; text: string }> = {
        active: {
          to: fromId,
          text: `✅ <b>${await getUserName(toId)}</b> sizning taklifingizni qabul qildi!\n\n💼 ${title}`
        },
        cancelled: {
          to: fromId,
          text: `❌ <b>${await getUserName(toId)}</b> taklifingizni rad etdi.\n\n💼 ${title}`
        },
        done_worker: {
          to: fromId,
          text: `🏁 <b>${await getUserName(toId)}</b> ishni tugatdi. Tasdiqlang!\n\n💼 ${title}`
        },
        done: {
          to: toId,
          text: `🏆 <b>${title}</b> — muvaffaqiyatli yakunlandi!\n\n⭐ Baholashni unutmang.`
        }
      };

      const notify = msgs[newSt];
      if (!notify) return new Response("no notify", { status: 200 });

      if (newSt === "done") {
        const tgFrom = await getTgId(fromId);
        const tgTo   = await getTgId(toId);
        if (tgFrom) await sendTg(tgFrom, `🏆 <b>${title}</b> — muvaffaqiyatli yakunlandi!\n⭐ Ishchini baholang.`);
        if (tgTo)   await sendTg(tgTo,   `🏆 <b>${title}</b> — muvaffaqiyatli yakunlandi!\n⭐ Mijozni baholang.`);
      } else {
        const tgId = await getTgId(notify.to);
        if (tgId) await sendTg(tgId, notify.text);
      }
    }

    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response("error", { status: 500 });
  }
});
