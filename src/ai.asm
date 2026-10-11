; =====================================================================
; ai.asm - Groq chat completions (text, vision, one-shot)
;
; Text travels through the whole program in its JSON-escaped form, so a
; Discord message can be dropped straight into the request body and the
; model reply straight into the Discord body: no unescape/escape pass.
; =====================================================================
%include "defs.inc"

extern sb_init, sb_free, sb_reset, sb_append, sb_appends, sb_putc, sb_append_u64
extern http_do, json_path, json_arr_next
extern settings_model, settings_maxhist, settings_append_persona
extern hist_snapshot, hist_add
extern sleep_ms, log_line, log_sb, memcmp
extern g_vision_model, g_groq_url, g_hdr_groq

; struct aireq
%define AI_H      0
%define AI_GUILD  8
%define AI_KEY    16              ; history key or NULL (no history, e.g. summarize)
%define AI_NAME   24
%define AI_NAMELN 32
%define AI_TEXT   40
%define AI_TEXTLN 48
%define AI_IMG    56              ; image url or NULL
%define AI_IMGLN  64
%define AI_OUT    72              ; sbuf* receiving the escaped reply

; locals of ai_run
%define L_REQ     0               ; sbuf request body
%define L_RESP    24              ; sbuf http response
%define L_TMP     48              ; sbuf scratch
%define L_HTTP    72              ; struct req (80 bytes)
%define L_JV1     152
%define L_JV2     176
%define L_JV3     200

section .rodata
q_model:     db '{"model":"', 0
q_sys:       db '","messages":[{"role":"system","content":"', 0
q_suffix1:   db "\n\nKamu lagi ngobrol di Discord sama user bernama ", 0
q_suffix2:   db ". PENTING: jangan pernah tulis nama user dalam format [nama] atau kurung kotak apapun di responmu. Langsung bales natural aja kayak ngobrol biasa.", 0
q_sys_end:   db '"},', 0
q_user_open: db '{"role":"user","content":"', 0
q_user_end:  db '"}', 0
q_img_open:  db '{"role":"user","content":[{"type":"image_url","image_url":{"url":"', 0
q_img_mid:   db '"}},{"type":"text","text":"', 0
q_img_end:   db '"}]}', 0
q_tail:      db '],"max_completion_tokens":2048,"temperature":0.8', 0
q_extra_oss: db ',"reasoning_effort":"low"', 0
q_extra_qw:  db ',"reasoning_format":"hidden"', 0
q_close:     db '}', 0
q_pre_oss:   db "openai/gpt-oss"
q_pre_qw:    db "qwen/"
q_imgtag:    db "[kirim gambar] ", 0
s_ua:        db "CaineASM/1.0", 0
s_aierr:     db "AI error: HTTP ", 0
s_ainet:     db "AI error: network failure, curl code ", 0
s_aiempty:   db "AI error: response has no message content", 0
s_ch:        db "choices", 0
s_mc:        db "message.content", 0

section .text

; int ai_run(aireq *r)   0 = reply stored in r->out, -1 = failure
global ai_run
ai_run:
    ENTER 232
    mov r12, rdi
    lea rdi, [rsp + L_REQ]
    call sb_init
    lea rdi, [rsp + L_RESP]
    call sb_init
    lea rdi, [rsp + L_TMP]
    call sb_init

    ; ---- model ----
    cmp qword [r12 + AI_IMG], 0
    je .textmodel
    mov r13, [rel g_vision_model]
    jmp .gotmodel
.textmodel:
    mov rdi, [r12 + AI_GUILD]
    call settings_model
    mov r13, rax
.gotmodel:
    lea rbx, [rsp + L_REQ]
    mov rdi, rbx
    lea rsi, [rel q_model]
    call sb_appends
    mov rdi, rbx
    mov rsi, r13
    call sb_appends
    mov rdi, rbx
    lea rsi, [rel q_sys]
    call sb_appends

    ; ---- system prompt (persona [+ who is talking]) ----
    mov rdi, rbx
    mov rsi, [r12 + AI_GUILD]
    call settings_append_persona
    cmp qword [r12 + AI_IMG], 0
    jne .nosuffix                   ; vision calls use the bare persona (as the Go bot did)
    mov rdi, rbx
    lea rsi, [rel q_suffix1]
    call sb_appends
    mov rdi, rbx
    mov rsi, [r12 + AI_NAME]
    mov rdx, [r12 + AI_NAMELN]
    call sb_append
    mov rdi, rbx
    lea rsi, [rel q_suffix2]
    call sb_appends
.nosuffix:
    mov rdi, rbx
    lea rsi, [rel q_sys_end]
    call sb_appends

    ; ---- history ----
    cmp qword [r12 + AI_IMG], 0
    jne .nohist
    mov rax, [r12 + AI_KEY]
    test rax, rax
    jz .nohist
    mov rdi, [r12 + AI_GUILD]
    call settings_maxhist
    mov r14, rax
    shl r14, 1
    mov rdi, [r12 + AI_KEY]
    mov rsi, r14
    mov rdx, rbx
    call hist_snapshot
.nohist:
    ; ---- the new user turn ----
    cmp qword [r12 + AI_IMG], 0
    jne .image
    mov rdi, rbx
    lea rsi, [rel q_user_open]
    call sb_appends
    mov rdi, rbx
    mov rsi, [r12 + AI_TEXT]
    mov rdx, [r12 + AI_TEXTLN]
    call sb_append
    mov rdi, rbx
    lea rsi, [rel q_user_end]
    call sb_appends
    jmp .tail
.image:
    mov rdi, rbx
    lea rsi, [rel q_img_open]
    call sb_appends
    mov rdi, rbx
    mov rsi, [r12 + AI_IMG]
    mov rdx, [r12 + AI_IMGLN]
    call sb_append
    mov rdi, rbx
    lea rsi, [rel q_img_mid]
    call sb_appends
    mov rdi, rbx
    mov rsi, [r12 + AI_TEXT]
    mov rdx, [r12 + AI_TEXTLN]
    call sb_append
    mov rdi, rbx
    lea rsi, [rel q_img_end]
    call sb_appends
.tail:
    mov rdi, rbx
    lea rsi, [rel q_tail]
    call sb_appends
    ; reasoning knobs depend on the model family (Groq reasoning docs)
    mov rdi, r13
    lea rsi, [rel q_pre_oss]
    mov edx, 14
    CALLC memcmp
    test eax, eax
    jnz .notoss
    mov rdi, rbx
    lea rsi, [rel q_extra_oss]
    call sb_appends
    jmp .endreq
.notoss:
    mov rdi, r13
    lea rsi, [rel q_pre_qw]
    mov edx, 5
    CALLC memcmp
    test eax, eax
    jnz .endreq
    mov rdi, rbx
    lea rsi, [rel q_extra_qw]
    call sb_appends
.endreq:
    mov rdi, rbx
    lea rsi, [rel q_close]
    call sb_appends

    ; ---- POST with up to 3 attempts (timeouts / 429 / 5xx are retried) ----
    xor r15d, r15d                  ; attempt
.try:
    inc r15d
    lea rdi, [rsp + L_RESP]
    call sb_reset
    mov rax, [r12 + AI_H]
    mov [rsp + L_HTTP + 0], rax
    mov qword [rsp + L_HTTP + 8], 1
    mov rax, [rel g_groq_url]
    mov [rsp + L_HTTP + 16], rax
    mov rax, [rel g_hdr_groq]
    mov [rsp + L_HTTP + 24], rax
    lea rax, [rel s_ua]
    mov [rsp + L_HTTP + 32], rax
    mov rax, [rbx + SB_DATA]
    mov [rsp + L_HTTP + 40], rax
    mov rax, [rbx + SB_LEN]
    mov [rsp + L_HTTP + 48], rax
    lea rax, [rsp + L_RESP]
    mov [rsp + L_HTTP + 56], rax
    mov qword [rsp + L_HTTP + 64], 0
    mov qword [rsp + L_HTTP + 72], 30
    lea rdi, [rsp + L_HTTP]
    call http_do
    mov r13d, eax                   ; curl code
    test r13d, r13d
    jnz .retry
    mov rax, [rsp + L_HTTP + 64]
    cmp rax, 429
    je .retry
    cmp rax, 500
    jae .retry
    cmp rax, 200
    jne .httperr
    jmp .parse
.retry:
    cmp r15d, 3
    jae .failnet
    mov edi, 2000
    call sleep_ms
    jmp .try
.failnet:
    test r13d, r13d
    jz .httperr
    lea rdi, [rsp + L_TMP]
    call sb_reset
    lea rdi, [rsp + L_TMP]
    lea rsi, [rel s_ainet]
    call sb_appends
    lea rdi, [rsp + L_TMP]
    movsxd rsi, r13d
    call sb_append_u64
    lea rdi, [rsp + L_TMP]
    call log_sb_keep
    jmp .fail
.httperr:
    lea rdi, [rsp + L_TMP]
    call sb_reset
    lea rdi, [rsp + L_TMP]
    lea rsi, [rel s_aierr]
    call sb_appends
    lea rdi, [rsp + L_TMP]
    mov rsi, [rsp + L_HTTP + 64]
    call sb_append_u64
    lea rdi, [rsp + L_TMP]
    mov esi, ' '
    call sb_putc
    mov rdx, [rsp + L_RESP + SB_LEN]
    cmp rdx, 400
    jbe .bl
    mov edx, 400
.bl:
    lea rdi, [rsp + L_TMP]
    mov rsi, [rsp + L_RESP + SB_DATA]
    call sb_append
    lea rdi, [rsp + L_TMP]
    call log_sb_keep
    jmp .fail

.parse:
    mov rdi, [rsp + L_RESP + SB_DATA]
    mov rsi, [rsp + L_RESP + SB_LEN]
    lea rdx, [rel s_ch]
    lea rcx, [rsp + L_JV1]
    call json_path
    test eax, eax
    jz .empty
    cmp qword [rsp + L_JV1 + JV_TYPE], 'a'
    jne .empty
    mov rdi, [rsp + L_JV1 + JV_PTR]
    mov rsi, rdi
    add rsi, [rsp + L_JV1 + JV_LEN]
    inc rdi
    lea rdx, [rsp + L_JV2]
    call json_arr_next
    test rax, rax
    jz .empty
    cmp qword [rsp + L_JV2 + JV_TYPE], 'o'
    jne .empty
    mov rdi, [rsp + L_JV2 + JV_PTR]
    mov rsi, [rsp + L_JV2 + JV_LEN]
    lea rdx, [rel s_mc]
    lea rcx, [rsp + L_JV3]
    call json_path
    test eax, eax
    jz .empty
    cmp qword [rsp + L_JV3 + JV_TYPE], 's'
    jne .empty
    cmp qword [rsp + L_JV3 + JV_LEN], 0
    je .empty
    mov r14, [r12 + AI_OUT]
    mov rdi, r14
    mov rsi, [rsp + L_JV3 + JV_PTR]
    mov rdx, [rsp + L_JV3 + JV_LEN]
    call sb_append

    ; ---- remember the exchange ----
    mov rax, [r12 + AI_KEY]
    test rax, rax
    jz .ok
    mov rdi, [r12 + AI_GUILD]
    call settings_maxhist
    shl rax, 1
    mov r15, rax                    ; entry limit
    ; user side (vision turns are tagged like the Go bot did)
    cmp qword [r12 + AI_IMG], 0
    je .plainuser
    lea rdi, [rsp + L_TMP]
    call sb_reset
    lea rdi, [rsp + L_TMP]
    lea rsi, [rel q_imgtag]
    call sb_appends
    lea rdi, [rsp + L_TMP]
    mov rsi, [r12 + AI_TEXT]
    mov rdx, [r12 + AI_TEXTLN]
    call sb_append
    mov rdi, [r12 + AI_KEY]
    xor esi, esi
    mov rdx, [rsp + L_TMP + SB_DATA]
    mov rcx, [rsp + L_TMP + SB_LEN]
    mov r8, r15
    call hist_add
    jmp .asst
.plainuser:
    mov rdi, [r12 + AI_KEY]
    xor esi, esi
    mov rdx, [r12 + AI_TEXT]
    mov rcx, [r12 + AI_TEXTLN]
    mov r8, r15
    call hist_add
.asst:
    mov rdi, [r12 + AI_KEY]
    mov esi, 1
    mov rdx, [rsp + L_JV3 + JV_PTR]
    mov rcx, [rsp + L_JV3 + JV_LEN]
    mov r8, r15
    call hist_add
.ok:
    xor r13d, r13d
    jmp .done
.empty:
    lea rdi, [rel s_aiempty]
    call log_line
.fail:
    mov r13d, -1
.done:
    lea rdi, [rsp + L_REQ]
    call sb_free
    lea rdi, [rsp + L_RESP]
    call sb_free
    lea rdi, [rsp + L_TMP]
    call sb_free
    mov eax, r13d
    LEAVE_RET

; print an sbuf as one log line without freeing it
log_sb_keep:
    push rbx
    mov rdi, [rdi + SB_DATA]
    call log_line
    pop rbx
    ret
