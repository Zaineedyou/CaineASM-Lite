# CaineASM Lite

Versi Assembly (NASM x86-64) dari bot Discord CaineGO, **hanya fitur AI**. Pakai Groq untuk chat + vision, libcurl untuk HTTPS/TLS. Gateway WebSocket (RFC 6455) ditulis manual di assembly.

## Fitur
- Chat AI: trigger lewat prefix (`Caine halo`), mention bot, atau reply ke pesan bot
- Vision: kirim gambar sebagai attachment, otomatis pakai model vision
- History per user per channel (in-memory, hilang saat restart)
- Rate limit AI per user + cooldown anti-spam
- Command admin (Manage Server / owner): `Caine setpersona <teks|reset>`, `Caine setmodel <gpt120b|gpt20b|qwen27b>`, `Caine sethistory <5-100>`, `Caine summarize [1-100]`
- Pengaturan per server disimpan di `DATA_FILE` (file teks)
- Auto reconnect + resume gateway, heartbeat/zombie detection, retry 429/5xx

## Yang dibuang dari versi Go
Moderasi, leveling, AFK, welcome, bridge, slash command, PostgreSQL, custom status. Command moderasi lama sekarang jatuh ke chat AI biasa.

## Perubahan
- Model default diganti karena model lama deprecated di Groq: text `openai/gpt-oss-120b`, vision `qwen/qwen3.8-27b`
- Pakai `max_completion_tokens`, `reasoning_effort: low` (gpt-oss) / `reasoning_format: hidden` (qwen)
- `allowed_mentions` hanya user (tidak bisa ping @everyone)
- `sethistory` benar-benar dipakai; `summarize` dibatasi 1–100 dan tidak masuk history

## Build & jalan
Butuh `nasm`, `gcc`, `make`, `libcurl4-openssl-dev`.

```
make
cp .env.example .env   # isi DISCORD_TOKEN & GROQ_API_KEY
./caine
```

Docker: `docker compose up -d --build`

Aktifkan **Message Content Intent** di Discord Developer Portal.

## Env
DISCORD_TOKEN, GROQ_API_KEY (wajib); BOT_PREFIX (Caine), SYSTEM_PROMPT, BOT_OWNER_ID, MAX_HISTORY (30), AI_RATE_MAX (10), AI_RATE_WINDOW_SEC (60), DATA_FILE, DEFAULT_MODEL, VISION_MODEL.

## Status tes
Dites penuh terhadap mock lokal (gateway + REST + Groq via TLS), unit test util/json/state, dan valgrind. Belum dites langsung ke Discord/Groq asli.

## Lisensi
Kode sumber CaineASM Lite dilisensikan di bawah **GNU Affero General Public License v3.0 saja** (`AGPL-3.0-only`). Lihat [LICENSE](LICENSE) untuk teks lengkap.
