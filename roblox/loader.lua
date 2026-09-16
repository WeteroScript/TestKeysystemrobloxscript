# -*- coding: utf-8 -*-
# MEREDIOS key system — FastAPI + Telegram bot + SQLite
import os, sqlite3, secrets, time, asyncio, logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, Header
from fastapi.responses import JSONResponse
import httpx
import uvicorn

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("meredios")

# ---------- config ----------
BOT_TOKEN   = os.environ.get("BOT_TOKEN", "").strip()
ADMIN_IDS   = {int(x) for x in os.environ.get("ADMIN_IDS", "5877790074").split(",") if x.strip()}
DB_PATH     = os.environ.get("DB_PATH", "keys.db")
PORT        = int(os.environ.get("PORT", "3000"))
API_SECRET  = os.environ.get("API_SECRET", "hK2pX9qLm4vN8sT1wZ6yB3cD7fG0jR5aQxYzWvUtSrPo").strip()
CHANNEL_ID  = int(os.environ.get("CHANNEL_ID", "-1003322076595"))
CHANNEL_URL = os.environ.get("CHANNEL_URL", "https://t.me/meredioshub")

TG = f"https://api.telegram.org/bot{BOT_TOKEN}"

KEY_PREFIX = "MerediosHUB-"
KEY_BODY_LEN = 24
ADMIN_TEST_KEY = "admintest"


# ---------- db ----------
def db_init():
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    con = sqlite3.connect(DB_PATH, timeout=10)
    con.executescript("""
    CREATE TABLE IF NOT EXISTS keys (
        key         TEXT PRIMARY KEY,
        created_at  INTEGER NOT NULL,
        expires_at  INTEGER NOT NULL,
        hwid        TEXT,
        bound_tg    INTEGER,
        bound_at    INTEGER,
        used_count  INTEGER DEFAULT 0,
        revoked     INTEGER DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_keys_hwid ON keys(hwid);
    CREATE INDEX IF NOT EXISTS idx_keys_tg   ON keys(bound_tg);
    """)
    con.commit()
    con.close()


def db():
    con = sqlite3.connect(DB_PATH, timeout=10)
    con.row_factory = sqlite3.Row
    return con


def gen_key():
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    body = "".join(secrets.choice(alphabet) for _ in range(KEY_BODY_LEN))
    return KEY_PREFIX + body


def get_user_key(user_id):
    con = db()
    row = con.execute("SELECT * FROM keys WHERE bound_tg=? AND revoked=0", (user_id,)).fetchone()
    con.close()
    return row


def create_key_for_user(user_id, days=30):
    now = int(time.time())
    exp = now + days * 86400
    con = db()
    con.execute("UPDATE keys SET revoked=1 WHERE bound_tg=? AND revoked=0", (user_id,))
    for _ in range(20):
        k = gen_key()
        try:
            con.execute(
                "INSERT INTO keys(key,created_at,expires_at,bound_tg,bound_at) VALUES(?,?,?,?,?)",
                (k, now, exp, user_id, now)
            )
            con.commit()
            row = con.execute("SELECT * FROM keys WHERE key=?", (k,)).fetchone()
            con.close()
            return row
        except sqlite3.IntegrityError:
            continue
    con.close()
    return None


# ---------- telegram ----------
async def tg_call(method, **payload):
    if not BOT_TOKEN:
        return {"ok": False}
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.post(f"{TG}/{method}", json=payload)
        return r.json()


async def tg_send(chat_id, text, reply_markup=None, parse_mode="HTML"):
    payload = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": parse_mode,
        "disable_web_page_preview": True,
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return await tg_call("sendMessage", **payload)


async def tg_edit(chat_id, message_id, text, reply_markup=None, parse_mode="HTML"):
    payload = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": text,
        "parse_mode": parse_mode,
        "disable_web_page_preview": True,
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return await tg_call("editMessageText", **payload)


async def tg_answer_cb(cb_id, text=None, show_alert=False):
    payload = {"callback_query_id": cb_id}
    if text:
        payload["text"] = text
        payload["show_alert"] = show_alert
    return await tg_call("answerCallbackQuery", **payload)


def is_admin(uid):
    return uid in ADMIN_IDS


async def is_subscribed(user_id):
    r = await tg_call("getChatMember", chat_id=CHANNEL_ID, user_id=user_id)
    if not r.get("ok"):
        log.warning("getChatMember failed: %s", r.get("description"))
        return True
    status = (r.get("result") or {}).get("status", "")
    return status in ("creator", "administrator", "member", "restricted")


# ---------- keyboards ----------
def kb_subscribe():
    return {"inline_keyboard": [
        [{"text": "📢 Подписаться", "url": CHANNEL_URL}],
        [{"text": "✅ Я подписался", "callback_data": "check_sub"}],
    ]}


def kb_main():
    return {"inline_keyboard": [
        [{"text": "🔑 Сгенерировать код", "callback_data": "gen"}],
        [{"text": "📋 Мой ключ", "callback_data": "mykey"}],
    ]}


def kb_mykey(has_key):
    rows = []
    if has_key:
        rows.append([{"text": "🔄 Сбросить привязку ключа", "callback_data": "reset"}])
    rows.append([{"text": "◀ Назад", "callback_data": "menu"}])
    return {"inline_keyboard": rows}


# ---------- text builders ----------
def fmt_key(row):
    now = int(time.time())
    left = max(0, row["expires_at"] - now)
    days = left // 86400
    if row["revoked"]:
        status = "🚫 отозван"
    elif left == 0:
        status = "⌛ истёк"
    else:
        status = f"✅ активен · {days} дн."
    hwid = row["hwid"]
    hwid_line = "— (не привязан к устройству)" if not hwid else f"<code>{hwid[:16]}…</code>"
    return (f"<b>🔑 Твой ключ</b>\n\n"
            f"<code>{row['key']}</code>\n\n"
            f"<b>Статус:</b> {status}\n"
            f"<b>HWID:</b> {hwid_line}\n"
            f"<b>Использований:</b> {row['used_count']}")


TEXT_SUBSCRIBE = (
    "<b>MEREDIOS</b>\n\n"
    "Чтобы получить доступ, подпишись на наш канал:\n"
    f"📢 {CHANNEL_URL}\n\n"
    "После подписки нажми <b>✅ Я подписался</b>."
)

TEXT_MENU = (
    "<b>MEREDIOS · главное меню</b>\n\n"
    "Здесь ты можешь получить свой ключ доступа и управлять им."
)

TEXT_NO_KEY = (
    "<b>📋 Мой ключ</b>\n\n"
    "У тебя пока нет ключа.\n"
    "Нажми <b>🔑 Сгенерировать код</b> в главном меню."
)


# ---------- callback handler ----------
async def handle_callback(cb):
    cb_id = cb["id"]
    user_id = cb["from"]["id"]
    chat_id = cb["message"]["chat"]["id"]
    message_id = cb["message"]["message_id"]
    data = cb.get("data", "")

    if data == "check_sub":
        if await is_subscribed(user_id):
            await tg_answer_cb(cb_id, "✅ Подписка подтверждена")
            await tg_edit(chat_id, message_id, TEXT_MENU, kb_main())
        else:
            await tg_answer_cb(cb_id, "❌ Ты ещё не подписался", show_alert=True)
        return

    if not await is_subscribed(user_id):
        await tg_answer_cb(cb_id, "❌ Сначала подпишись", show_alert=True)
        await tg_edit(chat_id, message_id, TEXT_SUBSCRIBE, kb_subscribe())
        return

    if data == "menu":
        await tg_answer_cb(cb_id)
        await tg_edit(chat_id, message_id, TEXT_MENU, kb_main())
        return

    if data == "gen":
        row = get_user_key(user_id)
        if row:
            await tg_answer_cb(cb_id, "🔑 У тебя уже есть ключ")
            await tg_edit(chat_id, message_id, fmt_key(row), kb_mykey(True))
            return
        row = create_key_for_user(user_id, days=30)
        if not row:
            await tg_answer_cb(cb_id, "❌ Ошибка генерации", show_alert=True)
            return
        await tg_answer_cb(cb_id, "✅ Ключ создан")
        await tg_edit(chat_id, message_id, fmt_key(row), kb_mykey(True))
        return

    if data == "mykey":
        row = get_user_key(user_id)
        if not row:
            await tg_answer_cb(cb_id)
            await tg_edit(chat_id, message_id, TEXT_NO_KEY, kb_mykey(False))
            return
        await tg_answer_cb(cb_id)
        await tg_edit(chat_id, message_id, fmt_key(row), kb_mykey(True))
        return

    if data == "reset":
        row = get_user_key(user_id)
        if not row:
            await tg_answer_cb(cb_id, "❌ Ключ не найден", show_alert=True)
            return
        con = db()
        con.execute("UPDATE keys SET hwid=NULL WHERE key=?", (row["key"],))
        con.commit()
        con.close()
        row = get_user_key(user_id)
        await tg_answer_cb(cb_id, "✅ Привязка сброшена")
        await tg_edit(chat_id, message_id, fmt_key(row), kb_mykey(True))
        return

    await tg_answer_cb(cb_id, "❓ Неизвестная команда", show_alert=True)


# ---------- message handler ----------
async def handle_message(msg):
    text = (msg.get("text") or "").strip()
    chat_id = msg["chat"]["id"]
    user_id = msg["from"]["id"]
    username = msg["from"].get("username") or msg["from"].get("first_name") or "user"

    if not text.startswith("/"):
        return

    parts = text.split()
    cmd = parts[0].split("@")[0].lower()
    args = parts[1:]

    if cmd == "/start":
        if not await is_subscribed(user_id):
            await tg_send(chat_id, TEXT_SUBSCRIBE, kb_subscribe())
            return
        await tg_send(chat_id, TEXT_MENU, kb_main())
        return

    if cmd == "/whoami":
        await tg_send(chat_id, f"TG id: <code>{user_id}</code>\nUsername: @{username}")
        return

    if cmd == "/mykey":
        row = get_user_key(user_id)
        if not row:
            await tg_send(chat_id, TEXT_NO_KEY, kb_mykey(False))
            return
        await tg_send(chat_id, fmt_key(row), kb_mykey(True))
        return

    if cmd == "/key":
        if not args:
            await tg_send(chat_id, "Формат: <code>/key ТВОЙ-КЛЮЧ</code>")
            return
        key = args[0].strip().upper()
        con = db()
        row = con.execute("SELECT * FROM keys WHERE key=?", (key,)).fetchone()
        if not row:
            con.close(); await tg_send(chat_id, "❌ Ключ не найден."); return
        if row["revoked"]:
            con.close(); await tg_send(chat_id, "❌ Ключ отозван."); return
        if row["expires_at"] < int(time.time()):
            con.close(); await tg_send(chat_id, "❌ Ключ истёк."); return
        if row["bound_tg"] and row["bound_tg"] != user_id:
            con.close(); await tg_send(chat_id, "❌ Уже привязан к другому аккаунту."); return
        con.execute("UPDATE keys SET bound_tg=?, bound_at=? WHERE key=?",
                    (user_id, int(time.time()), key))
        con.commit()
        row = con.execute("SELECT * FROM keys WHERE key=?", (key,)).fetchone()
        con.close()
        await tg_send(chat_id, "✅ Привязан.\n\n" + fmt_key(row), kb_mykey(True))
        return

    if not is_admin(user_id):
        await tg_send(chat_id, "⛔ Нет доступа.")
        return

    if cmd == "/genkey":
        count = int(args[0]) if args and args[0].isdigit() else 1
        days  = int(args[1]) if len(args) > 1 and args[1].isdigit() else 30
        count = max(1, min(count, 50))
        now = int(time.time())
        exp = now + days * 86400
        out = []
        con = db()
        for _ in range(count):
            k = gen_key()
            try:
                con.execute("INSERT INTO keys(key,created_at,expires_at) VALUES(?,?,?)",
                            (k, now, exp))
                out.append(k)
            except sqlite3.IntegrityError:
                continue
        con.commit(); con.close()
        await tg_send(chat_id,
            f"<b>Сгенерировано {len(out)} · {days} дн.</b>\n\n" +
            "\n".join(f"<code>{k}</code>" for k in out))
        return

    if cmd == "/listkeys":
        con = db()
        rows = con.execute("SELECT * FROM keys ORDER BY created_at DESC LIMIT 40").fetchall()
        con.close()
        if not rows:
            await tg_send(chat_id, "Пусто.")
            return
        lines = ["<b>Последние 40:</b>\n"]
        for r in rows:
            flag = "🚫" if r["revoked"] else ("⌛" if r["expires_at"] < time.time() else "✅")
            hwid = "•" if r["hwid"] else "—"
            tg = str(r["bound_tg"]) if r["bound_tg"] else "—"
            dl = max(0, (r["expires_at"] - int(time.time())) // 86400)
            lines.append(f"{flag} <code>{r['key']}</code> · {dl}d · hwid:{hwid} · tg:{tg} · {r['used_count']}")
        await tg_send(chat_id, "\n".join(lines))
        return

    if cmd == "/revoke":
        if not args:
            await tg_send(chat_id, "Формат: <code>/revoke КЛЮЧ</code>"); return
        con = db()
        cur = con.execute("UPDATE keys SET revoked=1 WHERE key=?", (args[0].upper(),))
        con.commit(); con.close()
        await tg_send(chat_id, "✅ Отозван." if cur.rowcount else "❌ Не найден.")
        return

    if cmd == "/rebind":
        if not args:
            await tg_send(chat_id, "Формат: <code>/rebind КЛЮЧ</code>"); return
        con = db()
        cur = con.execute("UPDATE keys SET hwid=NULL WHERE key=?", (args[0].upper(),))
        con.commit(); con.close()
        await tg_send(chat_id, "✅ HWID сброшен." if cur.rowcount else "❌ Не найден.")
        return

    if cmd == "/extend":
        if len(args) < 2 or not args[1].isdigit():
            await tg_send(chat_id, "Формат: <code>/extend КЛЮЧ ДНИ</code>"); return
        key, days = args[0].upper(), int(args[1])
        con = db()
        row = con.execute("SELECT * FROM keys WHERE key=?", (key,)).fetchone()
        if not row:
            con.close(); await tg_send(chat_id, "❌ Не найден."); return
        base = max(int(time.time()), row["expires_at"])
        new_exp = base + days * 86400
        con.execute("UPDATE keys SET expires_at=? WHERE key=?", (new_exp, key))
        con.commit(); con.close()
        await tg_send(chat_id, f"✅ До {time.strftime('%Y-%m-%d', time.localtime(new_exp))}")
        return

    if cmd == "/help":
        await tg_send(chat_id,
            "<b>Админ</b>\n"
            "/genkey [count] [days]\n"
            "/listkeys\n"
            "/revoke KEY\n"
            "/rebind KEY\n"
            "/extend KEY DAYS")
        return


# ---------- dispatcher ----------
async def handle_update(upd):
    try:
        if "callback_query" in upd:
            await handle_callback(upd["callback_query"])
            return
        msg = upd.get("message") or upd.get("edited_message")
        if msg:
            await handle_message(msg)
    except Exception:
        log.exception("update handler crashed")


# ---------- polling ----------
async def poll_loop():
    if not BOT_TOKEN:
        log.warning("BOT_TOKEN empty — bot disabled")
        return
    offset = 0
    async with httpx.AsyncClient(timeout=60) as client:
        while True:
            try:
                r = await client.get(f"{TG}/getUpdates",
                                     params={"offset": offset, "timeout": 30,
                                             "allowed_updates": '["message","callback_query","edited_message"]'})
                data = r.json()
                if not data.get("ok"):
                    log.warning("getUpdates not ok: %s", data)
                    await asyncio.sleep(3)
                    continue
                for upd in data.get("result", []):
                    offset = upd["update_id"] + 1
                    await handle_update(upd)
            except Exception as e:
                log.warning("poll err: %s", e)
                await asyncio.sleep(3)


# ---------- fastapi ----------
@asynccontextmanager
async def lifespan(app):
    db_init()
    task = asyncio.create_task(poll_loop())
    log.info("started · admins=%s · channel=%s · db=%s", ADMIN_IDS, CHANNEL_ID, DB_PATH)
    yield
    task.cancel()


app = FastAPI(lifespan=lifespan)


@app.get("/")
async def root():
    return {"ok": True, "service": "meredios-keys", "time": int(time.time())}


@app.post("/validate")
async def validate(req: Request, x_api_secret: str = Header(default="")):
    if API_SECRET and x_api_secret != API_SECRET:
        return JSONResponse({"ok": False, "status": "unauthorized"}, status_code=401)

    try:
        body = await req.json()
    except Exception:
        return JSONResponse({"ok": False, "status": "bad_json"}, status_code=400)

    key  = str(body.get("key", "")).strip()
    hwid = str(body.get("hwid", "")).strip()

    if not key or not hwid:
        return {"ok": False, "status": "missing_fields"}

    if key.lower() == ADMIN_TEST_KEY:
        return {
            "ok": True,
            "status": "admin_test",
            "expires_at": 9999999999,
            "days_left": 9999,
        }

    key_upper = key.upper()
    now = int(time.time())
    con = db()
    row = con.execute("SELECT * FROM keys WHERE key=?", (key_upper,)).fetchone()

    if not row:
        con.close()
        return {"ok": False, "status": "not_found"}

    if row["revoked"]:
        con.close()
        return {"ok": False, "status": "revoked"}

    if row["expires_at"] < now:
        con.close()
        return {"ok": False, "status": "expired", "expires_at": row["expires_at"]}

    stored_hwid = row["hwid"]

    if stored_hwid is None:
        con.execute("UPDATE keys SET hwid=?, used_count=used_count+1 WHERE key=?", (hwid, key_upper))
        con.commit()
        con.close()
        return {
            "ok": True,
            "status": "bound",
            "expires_at": row["expires_at"],
            "days_left": (row["expires_at"] - now) // 86400,
        }

    if stored_hwid != hwid:
        con.close()
        return {"ok": False, "status": "hwid_mismatch"}

    con.execute("UPDATE keys SET used_count=used_count+1 WHERE key=?", (key_upper,))
    con.commit()
    con.close()
    return {
        "ok": True,
        "status": "ok",
        "expires_at": row["expires_at"],
        "days_left": (row["expires_at"] - now) // 86400,
    }


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
