; =====================================================================
; bot.asm - Discord REST helpers, MESSAGE_CREATE filtering, worker
;           threads and the AI-related chat commands.
; =====================================================================
%include "defs.inc"

extern malloc, free, memcpy, memcmp, memmem, strcmp, strndup, strdup, pthread_create, pthread_detach
extern sb_init, sb_free, sb_reset, sb_append, sb_appends, sb_putc, sb_append_u64, sb_append_json_esc
extern json_get, json_path, json_arr_next, json_value, json_true
extern mem_ifind, ieq, parse_u64, trim_span, chunk_next, c_strlen, sleep_ms
extern http_new, http_free, http_do
extern ai_run
extern rl_fast, rl_ai, hist_clear
extern model_lookup, model_id_of, model_alias_of, settings_model, settings_maxhist
extern settings_set_model, settings_set_maxhist, settings_set_persona, model_list_text
extern log_line
extern g_prefix, g_prefix_len, g_prefix_esc, g_owner_id, g_api_base, g_hdr_discord
extern g_bot_id, g_active

%define MAX_WORKERS 24

section .rodata
s_ua_dc:      db "DiscordBot (https://github.com/Zaineedyou/CaineGO, 1.0)", 0
s_empty:      db 0
s_img_pref:   db "image/"
s_retry_after: db "retry_after", 0
p_channels:   db "/channels/", 0
p_messages:   db "/messages", 0
p_typing:     db "/typing", 0
p_limit:      db "/messages?limit=", 0
p_guilds:     db "/guilds/", 0
j_content:    db '{"content":"', 0
j_ref:        db '","message_reference":{"message_id":"', 0
j_tail:       db '","fail_if_not_exists":false},"allowed_mentions":{"parse":["users"],"replied_user":true}}', 0
k_owner:      db "owner_id", 0
k_roles:      db "roles", 0
k_id:         db "id", 0
k_perm:       db "permissions", 0
k_bot:        db "author.bot", 0
k_aid:        db "author.id", 0
k_aname:      db "author.username", 0
k_content:    db "content", 0
k_everyone:   db "mention_everyone", 0
k_mentions:   db "mentions", 0
k_refaid:     db "referenced_message.author.id", 0
k_channel:    db "channel_id", 0
k_msgid:      db "id", 0
k_guild:      db "guild_id", 0
k_nick:       db "member.nick", 0
k_mroles:     db "member.roles", 0
k_attach:     db "attachments", 0
k_ctype:      db "content_type", 0
k_url:        db "url", 0
s_roles_def:  db "[]", 0
s_log_drop:   db "worker limit reached, dropping a message", 0
s_log_thread: db "could not start worker thread", 0

; ---- command names ----
c_reset:      db "reset", 0
c_clear:      db "clear", 0
c_help:       db "help", 0
c_setpersona: db "setpersona", 0
c_setmodel:   db "setmodel", 0
c_sethistory: db "sethistory", 0
c_summarize:  db "summarize", 0

; ---- texts (JSON-escaped, "%P" = command prefix) ----
t_reset:     db "🧹 Memory kita udah di-reset sayang!", 0
t_help:      db "**Hai sayang! Ini cara pakai aku:**\n`%P <pertanyaan>` — tanya apapun\n`%P` + kirim gambar — analisis gambar\n`%P summarize [jumlah]` — rangkum chat\n`%P reset` — hapus memory\n`%P setmodel <alias>` — ganti model AI (admin)\n`%P setpersona <prompt>` — ganti persona AI (admin)\n`%P sethistory <angka>` — set batas history chat (admin)\n\nBisa juga mention aku atau reply pesanku.", 0
t_admin:     db "❌ Khusus admin.", 0
t_slow:      db "⏱️ Slow down! Kamu terlalu banyak ngirim pesan ke Caine. Tunggu sebentar ya.", 0
t_err:       db "❌ Ada error sayang, coba lagi ya 🙏", 0
t_nopersona: db "❌ Masukin persona-nya.", 0
t_persona_ok: db "✅ Persona Caine di server ini udah diupdate!", 0
t_model_cur: db "**Model saat ini:** `", 0
t_model_mid: db "`\n\n**Pilihan model:**\n", 0
t_model_ex:  db "\n\nContoh: `%P setmodel gpt120b`", 0
t_model_bad: db "❌ Model ga valid. Pilihan:\n", 0
t_model_ok1: db "✅ Model diganti ke `", 0
t_model_ok2: db "` (`", 0
t_model_ok3: db "`)!", 0
t_hist_cur1: db "📜 History limit sekarang: **", 0
t_hist_cur2: db "** pesan. Untuk mengubah: `%P sethistory <angka>`", 0
t_hist_bad:  db "❌ Masukkan angka antara 5-100.", 0
t_hist_ok1:  db "✅ History limit diset ke **", 0
t_hist_ok2:  db "** pesan.", 0
t_sum_none:  db "📭 Ga ada pesan yang bisa dirangkum.", 0
t_sum_getfail: db "❌ Gagal ambil pesan.", 0
t_sum_fail:  db "❌ Gagal merangkum.", 0
t_sum_head:  db "Rangkum percakapan berikut dalam beberapa poin penting:\n\n", 0
t_sum_name:  db "System", 0
t_empty_chat: db "Seseorang baru manggil namamu. Balas dengan sapaan mesra seperti pacar, jangan pakai kata bro.", 0
t_empty_img: db "Deskripsiin gambar ini.", 0
t_colon:     db ": ", 0
t_nl:        db "\n", 0

section .text

; =====================================================================
; REST helpers
; =====================================================================

; long parse_retry_ms(const char *p, size_t n)  "1.5" -> 1500 (3 decimals)
parse_retry_ms:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    call parse_u64
    imul rbx, rax, 1000
    add r12, rdx
    sub r13, rdx
    test r13, r13
    jz .d
    cmp byte [r12], '.'
    jne .d
    inc r12
    dec r13
    mov ecx, 100                    ; weight of the first decimal
.f:
    test r13, r13
    jz .d
    test ecx, ecx
    jz .d
    movzx eax, byte [r12]
    sub eax, '0'
    cmp eax, 9
    ja .d
    imul eax, ecx
    add rbx, rax
    mov eax, ecx
    xor edx, edx
    mov esi, 10
    div esi
    mov ecx, eax
    inc r12
    dec r13
    jmp .f
.d:
    mov rax, rbx
    LEAVE_RET

; long dc_do(CURL *h, long method, const char *path, const char *body, size_t blen, sbuf *resp)
; returns the HTTP status (0 when the transfer itself failed). One retry after a 429.
%define D_URL   0
%define D_HTTP  24
%define D_JV    104
%define D_RESP  128
dc_do:
    ENTER 160
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    mov [rsp + D_RESP], r9
    lea rdi, [rsp + D_URL]
    call sb_init
    lea rdi, [rsp + D_URL]
    mov rsi, [rel g_api_base]
    call sb_appends
    lea rdi, [rsp + D_URL]
    mov rsi, r14
    call sb_appends
    xor r14d, r14d                  ; attempt counter
.again:
    mov [rsp + D_HTTP + 0], r12
    mov [rsp + D_HTTP + 8], r13
    mov rax, [rsp + D_URL + SB_DATA]
    mov [rsp + D_HTTP + 16], rax
    mov rax, [rel g_hdr_discord]
    mov [rsp + D_HTTP + 24], rax
    lea rax, [rel s_ua_dc]
    mov [rsp + D_HTTP + 32], rax
    mov [rsp + D_HTTP + 40], r15
    mov [rsp + D_HTTP + 48], rbx
    mov rax, [rsp + D_RESP]
    mov [rsp + D_HTTP + 56], rax
    mov qword [rsp + D_HTTP + 64], 0
    mov qword [rsp + D_HTTP + 72], 20
    lea rdi, [rsp + D_HTTP]
    call http_do
    test eax, eax
    jnz .netfail
    mov rax, [rsp + D_HTTP + 64]
    cmp rax, 429
    jne .out
    test r14d, r14d
    jnz .out
    inc r14d
    ; wait retry_after (capped) and try once more
    mov rax, [rsp + D_RESP]
    mov rdi, [rax + SB_DATA]
    mov rsi, [rax + SB_LEN]
    lea rdx, [rel s_retry_after]
    lea rcx, [rsp + D_JV]
    mov qword [rsp + D_JV + JV_TYPE], 0
    call json_get
    mov ecx, 1000
    test eax, eax
    jz .sleep
    cmp qword [rsp + D_JV + JV_TYPE], 'd'
    jne .sleep
    mov rdi, [rsp + D_JV + JV_PTR]
    mov rsi, [rsp + D_JV + JV_LEN]
    call parse_retry_ms
    mov rcx, rax
    add rcx, 100
    cmp rcx, 10000
    jbe .sleep
    mov ecx, 10000
.sleep:
    mov edi, ecx
    call sleep_ms
    mov rax, [rsp + D_RESP]
    mov rdi, rax
    call sb_reset
    jmp .again
.netfail:
    xor eax, eax
    jmp .free
.out:
    mov rax, [rsp + D_HTTP + 64]
.free:
    mov r12, rax
    lea rdi, [rsp + D_URL]
    call sb_free
    mov rax, r12
    LEAVE_RET

; void path_channel(sbuf *sb, const char *channel_id, const char *suffix)
path_channel:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rel p_channels]
    call sb_appends
    mov rdi, rbx
    mov rsi, r12
    call sb_appends
    mov rdi, rbx
    mov rsi, r13
    call sb_appends
    LEAVE_RET

; void dc_typing(CURL *h, const char *channel)
dc_typing:
    ENTER 64                        ; [0] path sbuf, [24] resp sbuf
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp + 24]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r13
    lea rdx, [rel p_typing]
    call path_channel
    mov rdi, r12
    mov esi, 1
    mov rdx, [rsp + SB_DATA]
    lea rcx, [rel s_empty]
    xor r8d, r8d
    lea r9, [rsp + 24]
    call dc_do
    lea rdi, [rsp]
    call sb_free
    lea rdi, [rsp + 24]
    call sb_free
    LEAVE_RET

; long dc_send(CURL *h, const char *channel, const char *reply_to, const char *p, size_t n)
; posts p[0..n) (already JSON-escaped) as a reply
dc_send:
    ENTER 80                        ; [0] path sbuf, [24] body sbuf, [48] resp sbuf
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp + 24]
    call sb_init
    lea rdi, [rsp + 48]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r13
    lea rdx, [rel p_messages]
    call path_channel
    lea rdi, [rsp + 24]
    lea rsi, [rel j_content]
    call sb_appends
    lea rdi, [rsp + 24]
    mov rsi, r15
    mov rdx, rbx
    call sb_append
    lea rdi, [rsp + 24]
    lea rsi, [rel j_ref]
    call sb_appends
    lea rdi, [rsp + 24]
    mov rsi, r14
    call sb_appends
    lea rdi, [rsp + 24]
    lea rsi, [rel j_tail]
    call sb_appends
    mov rdi, r12
    mov esi, 1
    mov rdx, [rsp + SB_DATA]
    mov rcx, [rsp + 24 + SB_DATA]
    mov r8, [rsp + 24 + SB_LEN]
    lea r9, [rsp + 48]
    call dc_do
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    lea rdi, [rsp + 24]
    call sb_free
    lea rdi, [rsp + 48]
    call sb_free
    mov rax, r12
    LEAVE_RET

; ---------------------------------------------------------------------
; text helpers
; ---------------------------------------------------------------------

; void tpl_append(sbuf *sb, const char *tpl)   copies tpl, replacing "%P" with the prefix
tpl_append:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
.l:
    movzx eax, byte [r12]
    test al, al
    jz .d
    cmp al, '%'
    jne .plain
    cmp byte [r12 + 1], 'P'
    jne .plain
    mov rdi, rbx
    mov rsi, [rel g_prefix_esc]
    call sb_appends
    add r12, 2
    jmp .l
.plain:
    mov rdi, rbx
    movzx esi, al
    call sb_putc
    inc r12
    jmp .l
.d:
    LEAVE_RET

; void reply_text(CURL *h, job *j, const char *p, size_t n)  single reply
reply_text:
    mov r8, rcx
    mov rcx, rdx
    mov rdx, [rsi + JOB_MSGID]
    mov rsi, [rsi + JOB_CHANNEL]
    jmp dc_send

; void reply_tpl(CURL *h, job *j, const char *tpl)   one-message reply from a template
reply_tpl:
    ENTER 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r14
    call tpl_append
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + SB_DATA]
    mov rcx, [rsp + SB_LEN]
    call reply_text
    lea rdi, [rsp]
    call sb_free
    LEAVE_RET

; split a long reply into <=1900 byte messages and send each
; void reply_long(CURL *h, job *j, const char *p, size_t n)
reply_long:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
.l:
    test r15, r15
    jz .d
    mov rdi, r14
    mov rsi, r15
    mov edx, 1900
    call chunk_next
    mov rbx, rax                    ; bytes taken
    mov rdi, r14
    mov rsi, rbx
    call trim_span
    test rdx, rdx
    jz .skip
    mov rcx, rax                    ; trimmed ptr
    mov r8, rdx                     ; trimmed len
    mov rdi, r12
    mov rsi, [r13 + JOB_CHANNEL]
    mov rdx, [r13 + JOB_MSGID]
    call dc_send
.skip:
    add r14, rbx
    sub r15, rbx
    jmp .l
.d:
    LEAVE_RET

; size_t word_end(const char *p, size_t n)  length of the first token
; (ends at a space, tab, or the JSON escapes \n \r \t)
word_end:
    xor eax, eax
.l:
    cmp rax, rsi
    jae .d
    movzx ecx, byte [rdi + rax]
    cmp cl, ' '
    je .d
    cmp cl, 9
    je .d
    cmp cl, '\'
    jne .n
    lea rdx, [rax + 1]
    cmp rdx, rsi
    jae .n
    movzx ecx, byte [rdi + rdx]
    cmp cl, 'n'
    je .d
    cmp cl, 'r'
    je .d
    cmp cl, 't'
    je .d
.n:
    inc rax
    jmp .l
.d:
    ret

; void remove_all(sbuf *dst, const char *p, size_t n, const char *needle, size_t nlen)
remove_all:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
.l:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    CALLC memmem
    test rax, rax
    jz .rest
    mov rdx, rax
    sub rdx, r12                    ; bytes before the match
    mov rdi, rbx
    mov rsi, r12
    mov [rsp], rax
    call sb_append
    mov rax, [rsp]
    add rax, r15
    mov rcx, r12
    add rcx, r13
    sub rcx, rax                    ; bytes after the match
    mov r12, rax
    mov r13, rcx
    jmp .l
.rest:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_append
    LEAVE_RET

; int jv_eq_cstr(const jv *v, const char *s)  1 when the slice equals s
jv_eq_cstr:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov rdi, rsi
    call c_strlen
    cmp rax, [r12 + JV_LEN]
    jne .no
    mov rdi, [r12 + JV_PTR]
    mov rsi, r13
    mov rdx, rax
    test rdx, rdx
    jz .yes
    CALLC memcmp
    test eax, eax
    jnz .no
.yes:
    mov eax, 1
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; int getpath(const char *obj, size_t len, const char *path, jv *out)  (zeroes *out first)
getpath:
    mov qword [rcx + JV_TYPE], 0
    mov qword [rcx + JV_PTR], 0
    mov qword [rcx + JV_LEN], 0
    jmp json_path

; char *dup_typed(const jv *v, long type, const char *fallback)
dup_typed:
    ENTER 0
    cmp [rdi + JV_TYPE], rsi
    jne .fb
    cmp qword [rdi + JV_PTR], 0
    je .fb
    mov rax, [rdi + JV_PTR]
    mov rsi, [rdi + JV_LEN]
    mov rdi, rax
    CALLC strndup
    LEAVE_RET
.fb:
    mov rdi, rdx
    CALLC strdup
    LEAVE_RET

; =====================================================================
; permissions (admin-only commands)
; =====================================================================
; int is_admin(job *j, CURL *h)
%define A_PATH  0
%define A_RESP  24
%define A_J1    48
%define A_J2    72
%define A_J3    96
%define A_J4    120
%define A_J5    144
%define A_NEED  168
is_admin:
    ENTER 200
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d                  ; result
    lea rdi, [rsp + A_PATH]
    call sb_init
    lea rdi, [rsp + A_RESP]
    call sb_init
    lea rdi, [rsp + A_NEED]
    call sb_init
    ; bot owner from the environment
    mov rax, [rel g_owner_id]
    test rax, rax
    jz .api
    cmp byte [rax], 0
    je .api
    mov rdi, rax
    mov rsi, [r12 + JOB_AUTHOR]
    CALLC strcmp
    test eax, eax
    jnz .api
    mov r14d, 1
    jmp .done
.api:
    lea rdi, [rsp + A_PATH]
    lea rsi, [rel p_guilds]
    call sb_appends
    lea rdi, [rsp + A_PATH]
    mov rsi, [r12 + JOB_GUILD]
    call sb_appends
    mov rdi, r13
    xor esi, esi
    mov rdx, [rsp + A_PATH + SB_DATA]
    lea rcx, [rel s_empty]
    xor r8d, r8d
    lea r9, [rsp + A_RESP]
    call dc_do
    cmp rax, 200
    jne .done
    ; server owner
    mov rdi, [rsp + A_RESP + SB_DATA]
    mov rsi, [rsp + A_RESP + SB_LEN]
    lea rdx, [rel k_owner]
    lea rcx, [rsp + A_J1]
    call getpath
    cmp qword [rsp + A_J1 + JV_TYPE], 's'
    jne .roles
    lea rdi, [rsp + A_J1]
    mov rsi, [r12 + JOB_AUTHOR]
    call jv_eq_cstr
    test eax, eax
    jz .roles
    mov r14d, 1
    jmp .done
.roles:
    mov rdi, [rsp + A_RESP + SB_DATA]
    mov rsi, [rsp + A_RESP + SB_LEN]
    lea rdx, [rel k_roles]
    lea rcx, [rsp + A_J2]
    call getpath
    cmp qword [rsp + A_J2 + JV_TYPE], 'a'
    jne .done
    mov rbx, [rsp + A_J2 + JV_PTR]
    mov r15, rbx
    add r15, [rsp + A_J2 + JV_LEN]  ; end
    inc rbx                         ; cursor
.next:
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rsp + A_J3]
    call json_arr_next
    test rax, rax
    jz .done
    mov rbx, rax
    cmp qword [rsp + A_J3 + JV_TYPE], 'o'
    jne .next
    mov rdi, [rsp + A_J3 + JV_PTR]
    mov rsi, [rsp + A_J3 + JV_LEN]
    lea rdx, [rel k_id]
    lea rcx, [rsp + A_J4]
    call getpath
    mov rdi, [rsp + A_J3 + JV_PTR]
    mov rsi, [rsp + A_J3 + JV_LEN]
    lea rdx, [rel k_perm]
    lea rcx, [rsp + A_J5]
    call getpath
    cmp qword [rsp + A_J4 + JV_TYPE], 's'
    jne .next
    cmp qword [rsp + A_J5 + JV_TYPE], 's'
    jne .next
    mov rdi, [rsp + A_J5 + JV_PTR]
    mov rsi, [rsp + A_J5 + JV_LEN]
    call parse_u64
    test al, 8                      ; ADMINISTRATOR = 1 << 3
    jz .next
    ; the @everyone role has the same id as the guild
    lea rdi, [rsp + A_J4]
    mov rsi, [r12 + JOB_GUILD]
    call jv_eq_cstr
    test eax, eax
    jnz .yes
    ; does the author hold this role?  look for "<id>" in member.roles
    lea rdi, [rsp + A_NEED]
    call sb_reset
    lea rdi, [rsp + A_NEED]
    mov esi, '"'
    call sb_putc
    lea rdi, [rsp + A_NEED]
    mov rsi, [rsp + A_J4 + JV_PTR]
    mov rdx, [rsp + A_J4 + JV_LEN]
    call sb_append
    lea rdi, [rsp + A_NEED]
    mov esi, '"'
    call sb_putc
    mov rdi, [r12 + JOB_ROLES]
    call c_strlen
    mov rsi, rax
    mov rdi, [r12 + JOB_ROLES]
    mov rdx, [rsp + A_NEED + SB_DATA]
    mov rcx, [rsp + A_NEED + SB_LEN]
    CALLC memmem
    test rax, rax
    jz .next
.yes:
    mov r14d, 1
.done:
    lea rdi, [rsp + A_PATH]
    call sb_free
    lea rdi, [rsp + A_RESP]
    call sb_free
    lea rdi, [rsp + A_NEED]
    call sb_free
    mov eax, r14d
    LEAVE_RET

; =====================================================================
; commands (guild only)
; =====================================================================

; void h_setpersona(CURL *h, job *j, const char *args, size_t n)
h_setpersona:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, r13
    mov rsi, r12
    call is_admin
    test eax, eax
    jnz .ok
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel t_admin]
    call reply_tpl
    jmp .d
.ok:
    test r15, r15
    jnz .set
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel t_nopersona]
    call reply_tpl
    jmp .d
.set:
    mov rdi, [r13 + JOB_GUILD]
    mov rsi, r14
    mov rdx, r15
    call settings_set_persona
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel t_persona_ok]
    call reply_tpl
.d:
    LEAVE_RET

; void h_setmodel(CURL *h, job *j, const char *args, size_t n)
h_setmodel:
    ENTER 32                        ; [0] sbuf
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, r13
    mov rsi, r12
    call is_admin
    test eax, eax
    jnz .ok
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel t_admin]
    call reply_tpl
    jmp .d
.ok:
    lea rdi, [rsp]
    call sb_init
    test r15, r15
    jnz .set
    ; current model + list
    lea rdi, [rsp]
    lea rsi, [rel t_model_cur]
    call sb_appends
    mov rdi, [r13 + JOB_GUILD]
    call settings_model
    lea rdi, [rsp]
    mov rsi, rax
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel t_model_mid]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel model_list_text]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel t_model_ex]
    call tpl_append
    jmp .send
.set:
    mov rdi, r14
    mov rsi, r15
    call word_end
    mov rsi, rax
    mov rdi, r14
    call model_lookup
    test eax, eax
    jnz .valid
    lea rdi, [rsp]
    lea rsi, [rel t_model_bad]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel model_list_text]
    call sb_appends
    jmp .send
.valid:
    mov ebx, eax
    mov rdi, [r13 + JOB_GUILD]
    mov esi, ebx
    call settings_set_model
    lea rdi, [rsp]
    lea rsi, [rel t_model_ok1]
    call sb_appends
    movsxd rdi, ebx
    call model_alias_of
    lea rdi, [rsp]
    mov rsi, rax
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel t_model_ok2]
    call sb_appends
    movsxd rdi, ebx
    call model_id_of
    lea rdi, [rsp]
    mov rsi, rax
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel t_model_ok3]
    call sb_appends
.send:
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + SB_DATA]
    mov rcx, [rsp + SB_LEN]
    call reply_text
    lea rdi, [rsp]
    call sb_free
.d:
    LEAVE_RET

; void h_sethistory(CURL *h, job *j, const char *args, size_t n)
h_sethistory:
    ENTER 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, r13
    mov rsi, r12
    call is_admin
    test eax, eax
    jnz .ok
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel t_admin]
    call reply_tpl
    jmp .d
.ok:
    lea rdi, [rsp]
    call sb_init
    test r15, r15
    jnz .set
    lea rdi, [rsp]
    lea rsi, [rel t_hist_cur1]
    call sb_appends
    mov rdi, [r13 + JOB_GUILD]
    call settings_maxhist
    lea rdi, [rsp]
    mov rsi, rax
    call sb_append_u64
    lea rdi, [rsp]
    lea rsi, [rel t_hist_cur2]
    call tpl_append
    jmp .send
.set:
    mov rdi, r14
    mov rsi, r15
    call word_end
    mov rbx, rax                    ; token length
    mov rdi, r14
    mov rsi, rbx
    call parse_u64
    cmp rdx, rbx
    jne .bad
    cmp rax, 5
    jb .bad
    cmp rax, 100
    ja .bad
    mov rbx, rax
    mov rdi, [r13 + JOB_GUILD]
    mov rsi, rbx
    call settings_set_maxhist
    lea rdi, [rsp]
    lea rsi, [rel t_hist_ok1]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, rbx
    call sb_append_u64
    lea rdi, [rsp]
    lea rsi, [rel t_hist_ok2]
    call sb_appends
    jmp .send
.bad:
    lea rdi, [rsp]
    lea rsi, [rel t_hist_bad]
    call sb_appends
.send:
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + SB_DATA]
    mov rcx, [rsp + SB_LEN]
    call reply_text
    lea rdi, [rsp]
    call sb_free
.d:
    LEAVE_RET

; void h_summarize(CURL *h, job *j, const char *args, size_t n)
%define S_ITEMS  0                  ; 100 jv slots
%define S_PATH   2400
%define S_RESP   2424
%define S_PROMPT 2448
%define S_OUT    2472
%define S_REQ    2496               ; aireq, 80 bytes
%define S_J1     2576
%define S_J2     2600
%define S_J3     2624
h_summarize:
    ENTER 2656
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov ebx, 30                     ; default message count
    test r15, r15
    jz .limit
    mov rdi, r14
    mov rsi, r15
    call word_end
    mov [rsp + S_J1], rax
    mov rdi, r14
    mov rsi, rax
    call parse_u64
    test rdx, rdx
    jz .limit
    cmp rdx, [rsp + S_J1]
    jne .limit
    mov rbx, rax
.limit:
    test rbx, rbx
    jnz .l1
    mov ebx, 1
.l1:
    cmp rbx, 100
    jbe .l2
    mov ebx, 100
.l2:
    lea rdi, [rsp + S_PATH]
    call sb_init
    lea rdi, [rsp + S_RESP]
    call sb_init
    lea rdi, [rsp + S_PROMPT]
    call sb_init
    lea rdi, [rsp + S_OUT]
    call sb_init
    ; GET /channels/<id>/messages?limit=N
    lea rdi, [rsp + S_PATH]
    mov rsi, [r13 + JOB_CHANNEL]
    lea rdx, [rel p_limit]
    call path_channel
    lea rdi, [rsp + S_PATH]
    mov rsi, rbx
    call sb_append_u64
    mov rdi, r12
    xor esi, esi
    mov rdx, [rsp + S_PATH + SB_DATA]
    lea rcx, [rel s_empty]
    xor r8d, r8d
    lea r9, [rsp + S_RESP]
    call dc_do
    cmp rax, 200
    jne .getfail
    mov rdi, [rsp + S_RESP + SB_DATA]
    mov rsi, rdi
    add rsi, [rsp + S_RESP + SB_LEN]
    lea rdx, [rsp + S_J1]
    call json_value
    test rax, rax
    jz .getfail
    cmp qword [rsp + S_J1 + JV_TYPE], 'a'
    jne .getfail
    ; collect the messages (newest first in the API response)
    mov rbx, [rsp + S_J1 + JV_PTR]
    mov r15, rbx
    add r15, [rsp + S_J1 + JV_LEN]
    inc rbx
    xor r14d, r14d                  ; count
.collect:
    cmp r14d, 100
    jae .built
    mov rdi, rbx
    mov rsi, r15
    imul rax, r14, JV_SIZE
    lea rdx, [rsp + S_ITEMS + rax]
    call json_arr_next
    test rax, rax
    jz .built
    mov rbx, rax
    inc r14d
    jmp .collect
.built:
    lea rdi, [rsp + S_PROMPT]
    lea rsi, [rel t_sum_head]
    call sb_appends
    xor r15d, r15d                  ; lines written
    mov ebx, r14d                   ; walk oldest -> newest
.walk:
    test ebx, ebx
    jz .gen
    dec ebx
    imul rax, rbx, JV_SIZE
    lea r14, [rsp + S_ITEMS + rax]
    cmp qword [r14 + JV_TYPE], 'o'
    jne .walk
    mov rdi, [r14 + JV_PTR]
    mov rsi, [r14 + JV_LEN]
    lea rdx, [rel k_bot]
    lea rcx, [rsp + S_J2]
    call getpath
    lea rdi, [rsp + S_J2]
    call json_true
    test eax, eax
    jnz .walk
    mov rdi, [r14 + JV_PTR]
    mov rsi, [r14 + JV_LEN]
    lea rdx, [rel k_content]
    lea rcx, [rsp + S_J2]
    call getpath
    cmp qword [rsp + S_J2 + JV_TYPE], 's'
    jne .walk
    cmp qword [rsp + S_J2 + JV_LEN], 0
    je .walk
    mov rdi, [r14 + JV_PTR]
    mov rsi, [r14 + JV_LEN]
    lea rdx, [rel k_aname]
    lea rcx, [rsp + S_J3]
    call getpath
    test r15d, r15d
    jz .first
    lea rdi, [rsp + S_PROMPT]
    lea rsi, [rel t_nl]
    call sb_appends
.first:
    inc r15d
    cmp qword [rsp + S_J3 + JV_TYPE], 's'
    jne .noname
    lea rdi, [rsp + S_PROMPT]
    mov rsi, [rsp + S_J3 + JV_PTR]
    mov rdx, [rsp + S_J3 + JV_LEN]
    call sb_append
.noname:
    lea rdi, [rsp + S_PROMPT]
    lea rsi, [rel t_colon]
    call sb_appends
    lea rdi, [rsp + S_PROMPT]
    mov rsi, [rsp + S_J2 + JV_PTR]
    mov rdx, [rsp + S_J2 + JV_LEN]
    call sb_append
    jmp .walk
.gen:
    test r15d, r15d
    jnz .ask
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel t_sum_none]
    call reply_tpl
    jmp .free
.ask:
    mov [rsp + S_REQ + 0], r12      ; h
    mov rax, [r13 + JOB_GUILD]
    mov [rsp + S_REQ + 8], rax
    mov qword [rsp + S_REQ + 16], 0 ; no history
    lea rax, [rel t_sum_name]
    mov [rsp + S_REQ + 24], rax
    mov qword [rsp + S_REQ + 32], 6
    mov rax, [rsp + S_PROMPT + SB_DATA]
    mov [rsp + S_REQ + 40], rax
    mov rax, [rsp + S_PROMPT + SB_LEN]
    mov [rsp + S_REQ + 48], rax
    mov qword [rsp + S_REQ + 56], 0
    mov qword [rsp + S_REQ + 64], 0
    lea rax, [rsp + S_OUT]
    mov [rsp + S_REQ + 72], rax
    lea rdi, [rsp + S_REQ]
    call ai_run
    test eax, eax
    jnz .aifail
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + S_OUT + SB_DATA]
    mov rcx, [rsp + S_OUT + SB_LEN]
    call reply_long
    jmp .free
.aifail:
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel t_sum_fail]
    call reply_tpl
    jmp .free
.getfail:
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel t_sum_getfail]
    call reply_tpl
.free:
    lea rdi, [rsp + S_PATH]
    call sb_free
    lea rdi, [rsp + S_RESP]
    call sb_free
    lea rdi, [rsp + S_PROMPT]
    call sb_free
    lea rdi, [rsp + S_OUT]
    call sb_free
    LEAVE_RET

; =====================================================================
; one triggered message, run inside a worker thread
; =====================================================================
%define P_UT1   0
%define P_UT2   24
%define P_KEY   48
%define P_ND    72
%define P_OUT   96
%define P_REQ   120                 ; aireq (80 bytes)
%define P_TXT   200                 ; text ptr
%define P_TXTL  208
%define P_UP    216                 ; final user text
%define P_UN    224
%define P_NAME  232
%define P_AP    240
%define P_AN    248
%define P_WL    256

; void bot_process(job *j, CURL *h)
bot_process:
    ENTER 280
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rsp + P_UT1]
    call sb_init
    lea rdi, [rsp + P_UT2]
    call sb_init
    lea rdi, [rsp + P_KEY]
    call sb_init
    lea rdi, [rsp + P_ND]
    call sb_init
    lea rdi, [rsp + P_OUT]
    call sb_init

    ; ---------- user text ----------
    mov r14, [r12 + JOB_CONTENT]
    mov rdi, r14
    call c_strlen
    mov r15, rax                    ; content length
    mov rax, [r12 + JOB_FLAGS]
    test al, 1
    jz .nopfx
    mov rdi, r14
    mov rsi, r15
    mov rdx, [rel g_prefix]
    mov rcx, [rel g_prefix_len]
    call mem_ifind
    test rax, rax
    jz .copyall
    mov rbx, rax                    ; match start
    lea rdi, [rsp + P_UT1]
    mov rsi, r14
    mov rdx, rbx
    sub rdx, r14
    call sb_append
    add rbx, [rel g_prefix_len]
    lea rdi, [rsp + P_UT1]
    mov rsi, rbx
    mov rdx, r14
    add rdx, r15
    sub rdx, rbx
    call sb_append
    jmp .trim
.nopfx:
    test al, 2
    jz .copyall
    ; strip <@BOT> and <@!BOT>
    lea rdi, [rsp + P_ND]
    lea rsi, [rel s_mention1]
    call sb_appends
    lea rdi, [rsp + P_ND]
    lea rsi, [rel g_bot_id]
    call sb_appends
    lea rdi, [rsp + P_ND]
    mov esi, '>'
    call sb_putc
    lea rdi, [rsp + P_UT2]
    mov rsi, r14
    mov rdx, r15
    mov rcx, [rsp + P_ND + SB_DATA]
    mov r8, [rsp + P_ND + SB_LEN]
    call remove_all
    lea rdi, [rsp + P_ND]
    call sb_reset
    lea rdi, [rsp + P_ND]
    lea rsi, [rel s_mention2]
    call sb_appends
    lea rdi, [rsp + P_ND]
    lea rsi, [rel g_bot_id]
    call sb_appends
    lea rdi, [rsp + P_ND]
    mov esi, '>'
    call sb_putc
    lea rdi, [rsp + P_UT1]
    mov rsi, [rsp + P_UT2 + SB_DATA]
    mov rdx, [rsp + P_UT2 + SB_LEN]
    mov rcx, [rsp + P_ND + SB_DATA]
    mov r8, [rsp + P_ND + SB_LEN]
    call remove_all
    jmp .trim
.copyall:
    lea rdi, [rsp + P_UT1]
    mov rsi, r14
    mov rdx, r15
    call sb_append
.trim:
    mov rdi, [rsp + P_UT1 + SB_DATA]
    mov rsi, [rsp + P_UT1 + SB_LEN]
    call trim_span
    mov [rsp + P_UP], rax
    mov [rsp + P_UN], rdx

    ; ---------- history key + display name ----------
    mov rax, [r12 + JOB_GUILD]
    cmp byte [rax], 0
    jne .srv
    lea rdi, [rsp + P_KEY]
    lea rsi, [rel s_key_dm]
    call sb_appends
    lea rdi, [rsp + P_KEY]
    mov rsi, [r12 + JOB_AUTHOR]
    call sb_appends
    jmp .name
.srv:
    lea rdi, [rsp + P_KEY]
    lea rsi, [rel s_key_srv]
    call sb_appends
    lea rdi, [rsp + P_KEY]
    mov rsi, [r12 + JOB_CHANNEL]
    call sb_appends
.name:
    mov rax, [r12 + JOB_NICK]
    cmp byte [rax], 0
    jne .gotname
    mov rax, [r12 + JOB_USERNAME]
.gotname:
    mov [rsp + P_NAME], rax

    ; ---------- reset / help ----------
    mov rdi, [rsp + P_UP]
    mov rsi, [rsp + P_UN]
    lea rdx, [rel c_reset]
    call ieq
    test eax, eax
    jnz .reset
    mov rdi, [rsp + P_UP]
    mov rsi, [rsp + P_UN]
    lea rdx, [rel c_clear]
    call ieq
    test eax, eax
    jnz .reset
    mov rdi, [rsp + P_UP]
    mov rsi, [rsp + P_UN]
    lea rdx, [rel c_help]
    call ieq
    test eax, eax
    jnz .help

    ; ---------- guild-only AI commands ----------
    mov rax, [r12 + JOB_GUILD]
    cmp byte [rax], 0
    je .chat
    mov rdi, [rsp + P_UP]
    mov rsi, [rsp + P_UN]
    call word_end
    mov [rsp + P_WL], rax
    mov rdi, [rsp + P_UP]
    add rdi, rax
    mov rsi, [rsp + P_UN]
    sub rsi, rax
    call trim_span
    mov [rsp + P_AP], rax
    mov [rsp + P_AN], rdx
    mov rdi, [rsp + P_UP]
    mov rsi, [rsp + P_WL]
    lea rdx, [rel c_setpersona]
    call ieq
    test eax, eax
    jnz .cmd_persona
    mov rdi, [rsp + P_UP]
    mov rsi, [rsp + P_WL]
    lea rdx, [rel c_setmodel]
    call ieq
    test eax, eax
    jnz .cmd_model
    mov rdi, [rsp + P_UP]
    mov rsi, [rsp + P_WL]
    lea rdx, [rel c_sethistory]
    call ieq
    test eax, eax
    jnz .cmd_hist
    mov rdi, [rsp + P_UP]
    mov rsi, [rsp + P_WL]
    lea rdx, [rel c_summarize]
    call ieq
    test eax, eax
    jnz .cmd_sum
    jmp .chat

.reset:
    mov rdi, [rsp + P_KEY + SB_DATA]
    call hist_clear
    mov rdi, r13
    mov rsi, r12
    lea rdx, [rel t_reset]
    call reply_tpl
    jmp .free
.help:
    mov rdi, r13
    mov rsi, r12
    lea rdx, [rel t_help]
    call reply_tpl
    jmp .free
.cmd_persona:
    mov rdi, r13
    mov rsi, r12
    mov rdx, [rsp + P_AP]
    mov rcx, [rsp + P_AN]
    call h_setpersona
    jmp .free
.cmd_model:
    mov rdi, r13
    mov rsi, r12
    mov rdx, [rsp + P_AP]
    mov rcx, [rsp + P_AN]
    call h_setmodel
    jmp .free
.cmd_hist:
    mov rdi, r13
    mov rsi, r12
    mov rdx, [rsp + P_AP]
    mov rcx, [rsp + P_AN]
    call h_sethistory
    jmp .free
.cmd_sum:
    mov rdi, r13
    mov rsi, r12
    mov rdx, [rsp + P_AP]
    mov rcx, [rsp + P_AN]
    call h_summarize
    jmp .free

    ; ---------- normal AI chat (text or vision) ----------
.chat:
    mov rdi, [r12 + JOB_AUTHOR]
    call c_strlen
    mov rsi, rax
    mov rdi, [r12 + JOB_AUTHOR]
    call rl_ai
    test eax, eax
    jz .allowed
    mov rdi, r13
    mov rsi, r12
    lea rdx, [rel t_slow]
    call reply_tpl
    jmp .free
.allowed:
    mov rdi, r13
    mov rsi, [r12 + JOB_CHANNEL]
    call dc_typing
    mov rax, [rsp + P_UP]
    mov [rsp + P_TXT], rax
    mov rax, [rsp + P_UN]
    mov [rsp + P_TXTL], rax
    mov rbx, [r12 + JOB_IMAGE]
    cmp byte [rbx], 0
    jne .hasimg
    xor ebx, ebx                    ; no image
.hasimg:
    cmp qword [rsp + P_TXTL], 0
    jne .txtok
    lea rdi, [rel t_empty_chat]
    test rbx, rbx
    jz .deftxt
    lea rdi, [rel t_empty_img]
.deftxt:
    mov [rsp + P_TXT], rdi
    call c_strlen
    mov [rsp + P_TXTL], rax
.txtok:
    mov [rsp + P_REQ + 0], r13
    mov rax, [r12 + JOB_GUILD]
    mov [rsp + P_REQ + 8], rax
    mov rax, [rsp + P_KEY + SB_DATA]
    mov [rsp + P_REQ + 16], rax
    mov rax, [rsp + P_NAME]
    mov [rsp + P_REQ + 24], rax
    mov rdi, rax
    call c_strlen
    mov [rsp + P_REQ + 32], rax
    mov rax, [rsp + P_TXT]
    mov [rsp + P_REQ + 40], rax
    mov rax, [rsp + P_TXTL]
    mov [rsp + P_REQ + 48], rax
    mov [rsp + P_REQ + 56], rbx
    xor eax, eax
    test rbx, rbx
    jz .noimglen
    mov rdi, rbx
    call c_strlen
.noimglen:
    mov [rsp + P_REQ + 64], rax
    lea rax, [rsp + P_OUT]
    mov [rsp + P_REQ + 72], rax
    lea rdi, [rsp + P_REQ]
    call ai_run
    test eax, eax
    jnz .aierr
    mov rdi, r13
    mov rsi, r12
    mov rdx, [rsp + P_OUT + SB_DATA]
    mov rcx, [rsp + P_OUT + SB_LEN]
    call reply_long
    jmp .free
.aierr:
    mov rdi, r13
    mov rsi, r12
    lea rdx, [rel t_err]
    call reply_tpl
.free:
    lea rdi, [rsp + P_UT1]
    call sb_free
    lea rdi, [rsp + P_UT2]
    call sb_free
    lea rdi, [rsp + P_KEY]
    call sb_free
    lea rdi, [rsp + P_ND]
    call sb_free
    lea rdi, [rsp + P_OUT]
    call sb_free
    LEAVE_RET

; =====================================================================
; worker threads
; =====================================================================
job_free:
    ENTER 0
    mov rbx, rdi
    xor r12d, r12d
.l:
    cmp r12d, 72
    jae .d
    mov rdi, [rbx + r12]
    CALLC free
    add r12d, 8
    jmp .l
.d:
    mov rdi, rbx
    CALLC free
    LEAVE_RET

; void *job_thread(void *job)
job_thread:
    ENTER 0
    mov r12, rdi
    call http_new
    mov r13, rax
    test r13, r13
    jz .nohandle
    mov rdi, r12
    mov rsi, r13
    call bot_process
    mov rdi, r13
    call http_free
.nohandle:
    mov rdi, r12
    call job_free
    lock dec qword [rel g_active]
    xor eax, eax
    LEAVE_RET

; =====================================================================
; gateway MESSAGE_CREATE entry (runs on the gateway thread)
; =====================================================================
%define M_JA    0
%define M_JB    24
%define M_JC    48
%define M_JD    72
%define M_CPTR  96
%define M_CLEN  104
%define M_FLAGS 112
%define M_TID   120

; int is_bot_id(const char *p, size_t n)
is_bot_id:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rel g_bot_id]
    call c_strlen
    cmp rax, r13
    jne .no
    test rax, rax
    jz .no
    mov rdi, r12
    lea rsi, [rel g_bot_id]
    mov rdx, r13
    CALLC memcmp
    test eax, eax
    jnz .no
    mov eax, 1
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; void bot_on_message(const char *d, size_t dlen)   d = the event's "d" object
global bot_on_message
bot_on_message:
    ENTER 160
    mov r12, rdi
    mov r13, rsi
    ; ---- ignore bots (including ourselves) ----
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_bot]
    lea rcx, [rsp + M_JA]
    call getpath
    lea rdi, [rsp + M_JA]
    call json_true
    test eax, eax
    jnz .ret
    ; ---- author id ----
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_aid]
    lea rcx, [rsp + M_JA]
    call getpath
    cmp qword [rsp + M_JA + JV_TYPE], 's'
    jne .ret
    mov r14, [rsp + M_JA + JV_PTR]
    mov r15, [rsp + M_JA + JV_LEN]
    ; ---- per-user flood limit ----
    mov rdi, r14
    mov rsi, r15
    call rl_fast
    test eax, eax
    jnz .ret
    cmp byte [rel g_bot_id], 0
    je .ret
    ; ---- content ----
    mov qword [rsp + M_CPTR], 0
    mov qword [rsp + M_CLEN], 0
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_content]
    lea rcx, [rsp + M_JB]
    call getpath
    cmp qword [rsp + M_JB + JV_TYPE], 's'
    jne .nocontent
    mov rax, [rsp + M_JB + JV_PTR]
    mov [rsp + M_CPTR], rax
    mov rax, [rsp + M_JB + JV_LEN]
    mov [rsp + M_CLEN], rax
.nocontent:
    mov qword [rsp + M_FLAGS], 0
    ; prefix anywhere in the text (case-insensitive)
    cmp qword [rel g_prefix_len], 0
    je .noprefix
    cmp qword [rsp + M_CLEN], 0
    je .noprefix
    mov rdi, [rsp + M_CPTR]
    mov rsi, [rsp + M_CLEN]
    mov rdx, [rel g_prefix]
    mov rcx, [rel g_prefix_len]
    call mem_ifind
    test rax, rax
    jz .noprefix
    or qword [rsp + M_FLAGS], 1
.noprefix:
    ; @everyone counts as a mention (same as the Go bot)
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_everyone]
    lea rcx, [rsp + M_JA]
    call getpath
    lea rdi, [rsp + M_JA]
    call json_true
    test eax, eax
    jz .menc
    or qword [rsp + M_FLAGS], 2
.menc:
    ; explicit mention of the bot
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_mentions]
    lea rcx, [rsp + M_JA]
    call getpath
    cmp qword [rsp + M_JA + JV_TYPE], 'a'
    jne .noments
    mov rbx, [rsp + M_JA + JV_PTR]
    mov r14, rbx
    add r14, [rsp + M_JA + JV_LEN]
    inc rbx
.mloop:
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rsp + M_JC]
    call json_arr_next
    test rax, rax
    jz .noments
    mov rbx, rax
    cmp qword [rsp + M_JC + JV_TYPE], 'o'
    jne .mloop
    mov rdi, [rsp + M_JC + JV_PTR]
    mov rsi, [rsp + M_JC + JV_LEN]
    lea rdx, [rel k_id]
    lea rcx, [rsp + M_JD]
    call getpath
    cmp qword [rsp + M_JD + JV_TYPE], 's'
    jne .mloop
    mov rdi, [rsp + M_JD + JV_PTR]
    mov rsi, [rsp + M_JD + JV_LEN]
    call is_bot_id
    test eax, eax
    jz .mloop
    or qword [rsp + M_FLAGS], 2
.noments:
    ; reply to one of our messages
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_refaid]
    lea rcx, [rsp + M_JA]
    call getpath
    cmp qword [rsp + M_JA + JV_TYPE], 's'
    jne .checkflags
    mov rdi, [rsp + M_JA + JV_PTR]
    mov rsi, [rsp + M_JA + JV_LEN]
    call is_bot_id
    test eax, eax
    jz .checkflags
    or qword [rsp + M_FLAGS], 4
.checkflags:
    test qword [rsp + M_FLAGS], 7
    jz .ret

    ; ---- build the job ----
    mov edi, JOB_SIZE
    CALLC malloc
    test rax, rax
    jz .ret
    mov rbx, rax
    ; channel id
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_channel]
    lea rcx, [rsp + M_JA]
    call getpath
    lea rdi, [rsp + M_JA]
    mov esi, 's'
    lea rdx, [rel s_empty]
    call dup_typed
    mov [rbx + JOB_CHANNEL], rax
    ; message id
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_msgid]
    lea rcx, [rsp + M_JA]
    call getpath
    lea rdi, [rsp + M_JA]
    mov esi, 's'
    lea rdx, [rel s_empty]
    call dup_typed
    mov [rbx + JOB_MSGID], rax
    ; guild id (absent in DMs)
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_guild]
    lea rcx, [rsp + M_JA]
    call getpath
    lea rdi, [rsp + M_JA]
    mov esi, 's'
    lea rdx, [rel s_empty]
    call dup_typed
    mov [rbx + JOB_GUILD], rax
    ; author id
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_aid]
    lea rcx, [rsp + M_JA]
    call getpath
    lea rdi, [rsp + M_JA]
    mov esi, 's'
    lea rdx, [rel s_empty]
    call dup_typed
    mov [rbx + JOB_AUTHOR], rax
    ; username
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_aname]
    lea rcx, [rsp + M_JA]
    call getpath
    lea rdi, [rsp + M_JA]
    mov esi, 's'
    lea rdx, [rel s_empty]
    call dup_typed
    mov [rbx + JOB_USERNAME], rax
    ; nickname (null when unset)
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_nick]
    lea rcx, [rsp + M_JA]
    call getpath
    lea rdi, [rsp + M_JA]
    mov esi, 's'
    lea rdx, [rel s_empty]
    call dup_typed
    mov [rbx + JOB_NICK], rax
    ; content
    mov rdi, [rsp + M_CPTR]
    test rdi, rdi
    jnz .cdup
    lea rdi, [rel s_empty]
    CALLC strdup
    jmp .cdone
.cdup:
    mov rsi, [rsp + M_CLEN]
    CALLC strndup
.cdone:
    mov [rbx + JOB_CONTENT], rax
    ; member roles (array text, used for the admin check)
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_mroles]
    lea rcx, [rsp + M_JA]
    call getpath
    lea rdi, [rsp + M_JA]
    mov esi, 'a'
    lea rdx, [rel s_roles_def]
    call dup_typed
    mov [rbx + JOB_ROLES], rax
    ; first image attachment
    lea rax, [rel s_empty]
    mov qword [rsp + M_JD + JV_PTR], 0
    mov qword [rsp + M_JD + JV_TYPE], 0
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_attach]
    lea rcx, [rsp + M_JA]
    call getpath
    cmp qword [rsp + M_JA + JV_TYPE], 'a'
    jne .noatt
    mov r14, [rsp + M_JA + JV_PTR]
    mov r15, r14
    add r15, [rsp + M_JA + JV_LEN]
    inc r14
.aloop:
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rsp + M_JC]
    call json_arr_next
    test rax, rax
    jz .noatt
    mov r14, rax
    cmp qword [rsp + M_JC + JV_TYPE], 'o'
    jne .aloop
    mov rdi, [rsp + M_JC + JV_PTR]
    mov rsi, [rsp + M_JC + JV_LEN]
    lea rdx, [rel k_ctype]
    lea rcx, [rsp + M_JB]
    call getpath
    cmp qword [rsp + M_JB + JV_TYPE], 's'
    jne .aloop
    cmp qword [rsp + M_JB + JV_LEN], 6
    jb .aloop
    mov rdi, [rsp + M_JB + JV_PTR]
    lea rsi, [rel s_img_pref]
    mov edx, 6
    CALLC memcmp
    test eax, eax
    jnz .aloop
    mov rdi, [rsp + M_JC + JV_PTR]
    mov rsi, [rsp + M_JC + JV_LEN]
    lea rdx, [rel k_url]
    lea rcx, [rsp + M_JD]
    call getpath
.noatt:
    lea rdi, [rsp + M_JD]
    mov esi, 's'
    lea rdx, [rel s_empty]
    call dup_typed
    mov [rbx + JOB_IMAGE], rax
    mov rax, [rsp + M_FLAGS]
    and eax, 3
    mov [rbx + JOB_FLAGS], rax

    ; ---- hand over to a worker thread ----
    mov eax, 1
    lock xadd [rel g_active], rax
    cmp rax, MAX_WORKERS
    jae .busy
    lea rdi, [rsp + M_TID]
    xor esi, esi
    lea rdx, [rel job_thread]
    mov rcx, rbx
    CALLC pthread_create
    test eax, eax
    jnz .nothread
    mov rdi, [rsp + M_TID]
    CALLC pthread_detach
    jmp .ret
.busy:
    lock dec qword [rel g_active]
    lea rdi, [rel s_log_drop]
    call log_line
    mov rdi, rbx
    call job_free
    jmp .ret
.nothread:
    lock dec qword [rel g_active]
    lea rdi, [rel s_log_thread]
    call log_line
    mov rdi, rbx
    call job_free
.ret:
    LEAVE_RET

section .rodata
s_mention1:  db "<@", 0
s_mention2:  db "<@!", 0
s_key_dm:    db "dm-", 0
s_key_srv:   db "server-", 0
