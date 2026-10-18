; 128 direct-mapped, 192-byte expanded sprite slots (24 KiB).
; Tags include source row/variant, palette, direction and clipped height.
; Slots referenced by the current SGP list are pinned until completion.
%ifdef LOAD_SEG
SGP_CACHE_SEG equ LOAD_SEG + 3100h
%else
SGP_CACHE_SEG equ 7500h
%endif

sgp_cache_begin:
                pusha
                push es
                push cs
                pop es
                mov di,sgp_cache_used
                xor ax,ax
                mov cx,64
                rep stosw
                pop es
                popa
                ret

; Preserves registers. Sets source segment/offset, CF = cached hit.
; A pinned collision uses the existing per-frame staging buffer instead.
sgp_cache_get:  pusha
                mov ax,cs
                mov [cs:sgp_source_seg],ax
                mov ax,[cs:sgp_pixels_next]
                mov [cs:sgp_source_off],ax
                mov ax,si
                shr ax,2
                mov bx,[cs:d_table]
                shr bx,9
                xor ax,bx
                xor ax,[cs:d_step]
                xor ax,[cs:d_rows]
                and ax,127
                mov bp,ax
                shl ax,3
                mov bx,ax
                cmp si,[cs:sgp_cache_tags + bx]
                jne .miss
                mov ax,[cs:d_table]
                cmp ax,[cs:sgp_cache_tags + bx + 2]
                jne .miss
                mov ax,[cs:d_step]
                cmp ax,[cs:sgp_cache_tags + bx + 4]
                jne .miss
                mov ax,[cs:d_rows]
                cmp ax,[cs:sgp_cache_tags + bx + 6]
                jne .miss
                call .select
                popa
                stc
                ret
.miss:          cmp byte [cs:sgp_cache_used + bp],0
                jne .staging
                mov [cs:sgp_cache_tags + bx],si
                mov ax,[cs:d_table]
                mov [cs:sgp_cache_tags + bx + 2],ax
                mov ax,[cs:d_step]
                mov [cs:sgp_cache_tags + bx + 4],ax
                mov ax,[cs:d_rows]
                mov [cs:sgp_cache_tags + bx + 6],ax
                call .select
.staging:       popa
                clc
                ret
.select:        mov byte [cs:sgp_cache_used + bp],1
                imul ax,bp,192
                mov [cs:sgp_source_off],ax
                mov word [cs:sgp_source_seg],SGP_CACHE_SEG
                ret

sgp_source_seg  dw 0
sgp_source_off  dw 0
sgp_cache_used  times 128 db 0
sgp_cache_tags  times 128 * 4 dw 0
