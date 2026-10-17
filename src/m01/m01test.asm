; Copyright (c) 2026 Nakata Maho
;
; Redistribution and use in source and binary forms, with or without
; modification, are permitted provided that the following conditions
; are met:
; 1. Redistributions of source code must retain the above copyright
;    notice, this list of conditions and the following disclaimer.
; 2. Redistributions in binary form must reproduce the above copyright
;    notice, this list of conditions and the following disclaimer in the
;    documentation and/or other materials provided with the distribution.
;
; THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR
; IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
; OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
; IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
; INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
; BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
; USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
; ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
; THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;
; M01TEST: feasibility tests for running the arcade program in the uPD9002's
; Z80-compatible mode (docs/DESIGN.md).
;
; Loaded by src/boot/ipl.asm to 2000:0000. The builder (tools/build_m01.py)
; places the patched Z80 program at 2000:8000.
;
;   1  compatible-mode probes: run each Z80 snippet with BRKEM, return with
;      RETEM, and print the observed registers with PASS/FAIL
;   2  the game: run the program in compatible mode, inject RST 38h on each
;      VRTC interrupt, and show tile RAM as text every 30 frames
;   3  320x224 graphics at 15.98 kHz test pattern
;
; Native interrupt handling in compatible mode: the VRTC interrupt (IR2,
; INT 0Ah) is serviced in native mode and IRET resumes the Z80 code. To
; inject the Z80's mode 1 interrupt the handler pushes the Z80 PC on the
; Z80 stack (DS0:BP), sets the saved IP to 0038h and clears IE in the saved
; PSW, as a Z80 does when it accepts an interrupt.

		cpu	186
		org	0

Z80SEG		equ	5000h		; the 64 KiB compatible-mode space
ROM_OFFSET	equ	8000h		; patched program in this segment
ROM_BYTES	equ	4000h
Z80_STACK	equ	0d000h		; native stack while the Z80 code runs
BRKEM_VEC	equ	70h		; 40h-7Bh unused (technical manual, vector map)
VRTC_VEC	equ	0ah
ICU0		equ	188h
ICU1		equ	18ah

COUNTER		equ	0ff00h		; Z80 address: VRTC count (word)
PROBE_PC	equ	0100h		; Z80 address of the probe snippets

IN0		equ	5100h		; Z80 addresses of the redirected inputs
IN1		equ	5140h		; (tools/patches.py)
DSW		equ	5180h
DSW_DEFAULT	equ	0c9h		; 1 coin 1 credit, 3 lives, 10000, normal
COIN_FRAME	equ	600		; automatic coin and start (Z80 frames)
START_FRAME	equ	720
VIEW_FRAMES	equ	30

%macro BRKEM 1
		db	0fh, 0ffh, %1
%endmacro

start:		cli
		mov	ax,cs
		mov	ds,ax
		mov	es,ax
		mov	ss,ax
		mov	sp,0fffeh
		cld
		call	install
		sti

menu:		call	text_init
		mov	si,s_title
		call	puts
		mov	si,s_mask
		call	puts
		mov	al,[old_mask]
		call	puthex8
		mov	si,s_menu
		call	puts
.key:		call	wait_key
		cmp	al,'1'
		je	probes
		cmp	al,'2'
		je	game
		cmp	al,'3'
		je	video224
		jmp	.key

; ---------------------------------------------------------------------------
; Interrupt setup

install:	xor	ax,ax
		mov	es,ax
		mov	ax,[es:VRTC_VEC * 4]
		mov	[old_vrtc],ax
		mov	ax,[es:VRTC_VEC * 4 + 2]
		mov	[old_vrtc + 2],ax
		mov	word [es:VRTC_VEC * 4],vrtc
		mov	[es:VRTC_VEC * 4 + 2],cs
		mov	dx,ICU1
		in	al,dx
		mov	[old_mask],al
		test	al,04h			; IR2 already enabled: the ROM
		jnz	.masked			; has a handler; chain to it
		mov	byte [chain],1
.masked:	and	al,0fbh
		mov	[old_mask_ir2],al
		out	dx,al
		push	cs
		pop	es
		ret

; BRKEM_VEC -> Z80SEG:AX
set_entry:	push	es
		push	bx
		xor	bx,bx
		mov	es,bx
		mov	[es:BRKEM_VEC * 4],ax
		mov	word [es:BRKEM_VEC * 4 + 2],Z80SEG
		pop	bx
		pop	es
		ret

; ---------------------------------------------------------------------------
; VRTC interrupt

vrtc:		push	ax
		push	bx
		push	dx
		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		inc	word [COUNTER]
		inc	word [cs:frames]
		mov	bx,sp			; [bx+8] IP, [bx+10] CS, [bx+12] PSW
		cmp	word [ss:bx + 10],Z80SEG	; the Z80 code was interrupted?
		jne	.native			; (vaeg does not keep MD in PSW)
		mov	ax,[ss:bx + 12]
		mov	[cs:last_psw],ax
		mov	ax,[ss:bx + 8]
		mov	[cs:last_ip],ax
		inc	word [cs:z80_irqs]
		test	word [ss:bx + 12],0200h
		jnz	.ie_ok
		; An interrupt cannot be accepted with IE = 0; count a saved IE of
		; 0 (expected never) and return with IE = 1.
		inc	word [cs:ie0_irqs]
		or	word [ss:bx + 12],0200h
.ie_ok:		cmp	byte [cs:inject],0
		je	.eoi
		test	byte [5000h],1		; the program's interrupt enable
		jz	.eoi
		cmp	byte [cs:pac_mode],0
		je	.inject
		call	inputs
.inject:	sub	bp,2			; Z80 PUSH PC; PC = 0038h; DI
		mov	ax,[ss:bx + 8]
		mov	[ds:bp],ax
		mov	word [ss:bx + 8],0038h
		and	word [ss:bx + 12],0fdffh
		inc	word [cs:injected]
.eoi:		mov	al,20h
		mov	dx,ICU0
		out	dx,al
		cmp	word [cs:yield_at],0
		je	.ret
		mov	ax,[cs:z80_irqs]
		cmp	ax,[cs:yield_at]
		jb	.ret
		; Yield to the native main loop; resume_z80 continues here.
		push	cx
		push	si
		push	di
		push	bp
		push	es
		mov	[cs:z80_sp],sp
		mov	byte [cs:in_z80],0
		mov	sp,[cs:main_sp]
		push	cs
		pop	ds
		push	cs
		pop	es
		mov	al,[old_mask_ir2]	; other interrupts back for the BIOS
		mov	dx,ICU1
		out	dx,al
		ret
.ret:		pop	ds
		pop	dx
		pop	bx
		pop	ax
		iret
.native:	cmp	byte [cs:in_z80],0	; native code inside a Z80 run
		jne	.eoi_native		; (a BIOS handler): just EOI
		cmp	byte [cs:chain],0
		je	.eoi_native
		pop	ds
		pop	dx
		pop	bx
		pop	ax
		jmp	far [cs:old_vrtc]
.eoi_native:	mov	al,20h
		mov	dx,ICU0
		out	dx,al
		jmp	.ret

; The game's inputs, active low, from the Z80 frame count (DS = Z80SEG).
inputs:		mov	byte [IN0],0ffh
		mov	byte [IN1],0ffh
		mov	byte [DSW],DSW_DEFAULT
		mov	ax,[cs:injected]
		sub	ax,COIN_FRAME
		cmp	ax,5
		jae	.start
		and	byte [IN0],0dfh		; coin 1
.start:		mov	ax,[cs:injected]
		sub	ax,START_FRAME
		cmp	ax,5
		jae	.done
		and	byte [IN1],0dfh		; 1 player start
.done:		ret

; Called from the main loop; returns when the VRTC handler yields.
resume_z80:	cli
		call	mask_others
		mov	[main_sp],sp
		mov	sp,[z80_sp]
		mov	byte [in_z80],1
		pop	es
		pop	bp
		pop	di
		pop	si
		pop	cx
		jmp	vrtc.ret

; While the Z80 code runs only VRTC is enabled, so that the frame rhythm is
; not disturbed by BIOS handlers.
mask_others:	mov	al,0fbh
		mov	dx,ICU1
		out	dx,al
		ret

; First entry to the program at Z80 0000h; returns like resume_z80.
start_z80:	cli
		call	mask_others
		mov	[main_sp],sp
		mov	sp,Z80_STACK
		mov	byte [in_z80],1
		xor	ax,ax
		call	set_entry
		mov	ax,Z80SEG
		mov	ds,ax
		xor	ax,ax
		xor	bx,bx
		xor	cx,cx
		xor	dx,dx
		xor	si,si
		xor	di,di
		xor	bp,bp
		BRKEM	BRKEM_VEC
		; Not reached: the program never executes RETEM.
		jmp	$

; ---------------------------------------------------------------------------
; Probes

; Copy probe SI (CX bytes) to Z80 PROBE_PC, run it with the native
; registers DX (Z80 DE) set by the caller, and return the Z80 registers:
; AL = A, CX = BC, DX = DE, BX = HL.
run_probe:	push	es
		push	di
		mov	ax,Z80SEG
		mov	es,ax
		mov	di,PROBE_PC
		rep	movsb
		pop	di
		pop	es
		mov	ax,PROBE_PC
		call	set_entry
		push	ds
		push	bp
		mov	ax,Z80SEG
		mov	ds,ax
		mov	byte [cs:in_z80],1
		push	dx
		call	mask_others
		pop	dx
		xor	ax,ax
		xor	cx,cx
		xor	bx,bx
		sti
		BRKEM	BRKEM_VEC
		mov	byte [cs:in_z80],0
		push	ax
		push	dx
		mov	al,[cs:old_mask_ir2]
		mov	dx,ICU1
		out	dx,al
		pop	dx
		pop	ax
		pop	bp
		pop	ds
		ret

%macro PROBE 1				; snippet label
		mov	si,%1
		mov	cx,%1_end - %1
%endmacro

probes:		call	text_init
		mov	si,s_probes
		call	puts
		mov	ax,Z80SEG		; clear the Z80 space
		mov	es,ax
		xor	di,di
		xor	ax,ax
		mov	cx,8000h
		rep	stosw
		push	cs
		pop	es

		; im1
		mov	si,s_im1
		call	puts
		PROBE	z_im1
		call	run_probe
		mov	[r_a],al
		cmp	al,77h
		call	verdict
		mov	si,s_a
		call	puts
		mov	al,[r_a]
		call	puthex8
		call	crlf

		; index: IX, IY, EXX
		mov	si,s_index
		call	puts
		PROBE	z_index
		call	run_probe
		call	save_regs
		cmp	byte [r_a],0a5h
		jne	.index_v
		cmp	word [r_bc],1111h
		jne	.index_v
		cmp	word [r_hl],0ff31h
		jne	.index_v
		cmp	word [r_de],0ff40h
.index_v:	call	verdict
		call	show_regs

		; ld-i
		mov	si,s_ldi
		call	puts
		PROBE	z_ldi
		call	run_probe
		call	save_regs
		cmp	word [r_bc],5a00h	; B = I after 5Ah, C = I after 00h
		jne	.ldi_v
		test	byte [r_hl],0c0h	; F after LD A,I with I=5Ah: S=Z=0
		jnz	.ldi_v
		test	byte [r_de],40h		; F after LD A,I with I=00h: Z=1
		jnz	.ldi_ok
		or	al,1			; ZF = 0
		jmp	.ldi_v
.ldi_ok:	cmp	al,al
.ldi_v:		call	verdict
		call	show_regs

		; speed: loop iterations in one VRTC frame
		mov	si,s_speed
		call	puts
		PROBE	z_speed
		call	run_probe
		mov	[speed],bx
		mov	si,s_iter
		call	puts
		mov	ax,[speed]
		call	puthex16
		mov	si,s_psw
		call	puts
		mov	ax,[last_psw]
		call	puthex16
		call	crlf

		; di-masks: DI for about four frames, then EI. PASS: no VRTC is
		; counted under DI and counting resumes after EI. The count just
		; after EI shows whether a VRTC raised under DI was kept (1) or
		; lost (0).
		mov	si,s_di
		call	puts
		mov	ax,[speed]
		mov	dx,0ffffh
		mov	bx,0ffffh
		cmp	ax,4000h
		jae	.di_run
		or	ax,ax
		jz	.di_run
		shl	ax,1
		mov	bx,ax			; two frames
		shl	ax,1
		mov	dx,ax			; four frames
.di_run:	push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		mov	[0ff02h],bx
		pop	ds
		PROBE	z_di
		call	run_probe
		call	save_regs
		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		mov	ax,[0ff04h]
		pop	ds
		sub	ax,[r_bc]
		mov	[r_sp],ax
		mov	ax,[r_bc]		; count after the DI loop
		cmp	ax,[r_hl]		; count before it
		jne	.di_v
		cmp	[r_de],ax		; count two frames after EI
		je	.di_fail
		cmp	al,al
		jmp	.di_v
.di_fail:	or	al,1			; ZF = 0
.di_v:		call	verdict
		call	show_regs
		mov	si,s_kept
		call	puts
		mov	ax,[r_sp]
		call	puthex16
		call	crlf

		; inject-rst38: five injected interrupts
		mov	si,s_inject
		call	puts
		push	es
		mov	ax,Z80SEG
		mov	es,ax
		mov	si,z_isr
		mov	di,0038h
		mov	cx,z_isr_end - z_isr
		rep	movsb
		pop	es
		mov	byte [inject],1
		PROBE	z_inject
		call	run_probe
		mov	byte [inject],0
		call	save_regs
		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		mov	ax,[0ff20h]
		pop	ds
		mov	[r_sp],ax
		cmp	byte [r_a],5
		jb	.inj_v
		cmp	word [r_bc],1234h
		jne	.inj_v
		cmp	word [r_de],5678h
		jne	.inj_v
		cmp	word [r_hl],9abch
		jne	.inj_v
		cmp	word [r_sp],0fe00h
.inj_v:		call	verdict
		call	show_regs
		mov	si,s_sp
		call	puts
		mov	ax,[r_sp]
		call	puthex16
		call	crlf

		; ei-window: DI; EI in a loop for three frames. An interrupt taken
		; just after EI must have IE = 1 in its saved PSW.
		mov	si,s_eiw
		call	puts
		mov	word [ie0_irqs],0
		mov	ax,[z80_irqs]
		mov	[r_sp],ax
		PROBE	z_eiw
		call	run_probe
		mov	ax,[z80_irqs]
		sub	ax,[r_sp]
		mov	[r_sp],ax
		cmp	word [ie0_irqs],0
		call	verdict
		mov	si,s_irqs
		call	puts
		mov	ax,[r_sp]
		call	puthex16
		mov	si,s_ie0
		call	puts
		mov	ax,[ie0_irqs]
		call	puthex16
		call	crlf

		; ei-halt (last: a HALT that never ends hangs here)
		mov	si,s_halt
		call	puts
		PROBE	z_halt
		call	run_probe
		call	save_regs
		cmp	byte [r_a],55h
		jne	.halt_v
		mov	ax,[r_de]
		sub	ax,[r_hl]
		cmp	ax,1
		jb	.halt_f
		cmp	ax,2
		ja	.halt_f
		cmp	al,al
		jmp	.halt_v
.halt_f:	or	al,1
.halt_v:	call	verdict
		call	show_regs

		mov	si,s_done
		call	puts
		call	wait_key
		jmp	menu

save_regs:	mov	[r_a],al
		mov	[r_bc],cx
		mov	[r_de],dx
		mov	[r_hl],bx
		ret

; ZF = 1: PASS, else FAIL.
verdict:	mov	si,s_pass
		je	.p
		mov	si,s_fail
.p:		jmp	puts

show_regs:	mov	si,s_a
		call	puts
		mov	al,[r_a]
		call	puthex8
		mov	si,s_bc
		call	puts
		mov	ax,[r_bc]
		call	puthex16
		mov	si,s_de
		call	puts
		mov	ax,[r_de]
		call	puthex16
		mov	si,s_hl
		call	puts
		mov	ax,[r_hl]
		call	puthex16
		jmp	crlf

; ---------------------------------------------------------------------------
; The game run

game:		mov	ax,Z80SEG
		mov	es,ax
		xor	di,di
		mov	si,ROM_OFFSET
		mov	cx,ROM_BYTES / 2
		rep	movsw
		xor	ax,ax
		mov	cx,(10000h - ROM_BYTES) / 2
		rep	stosw
		push	cs
		pop	es
		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		mov	byte [IN0],0ffh
		mov	byte [IN1],0ffh
		mov	byte [DSW],DSW_DEFAULT
		pop	ds
		call	text_init
		mov	byte [pac_mode],1
		mov	byte [inject],1
		mov	word [yield_at],VIEW_FRAMES
		call	start_z80
.loop:		sti
		call	view
		mov	ax,[z80_irqs]
		add	ax,VIEW_FRAMES
		mov	[yield_at],ax
		call	resume_z80
		jmp	.loop

; Tile RAM 4000h-43FFh as text: the picture rotated so that the top of the
; game is on the left (36 columns); rows show arcade columns 27 down to 4.
view:		push	ds
		mov	cx,0			; CL: text row
.row:		push	cx
		mov	dl,cl			; DL: row, DH: column
		xor	dh,dh
		mov	ah,08h
		int	83h
		pop	cx
		push	cx
		mov	al,27
		sub	al,cl
		mov	[view_x],al
		xor	bx,bx			; BL: arcade row y
.col:		call	tile_offset		; SI = offset in tile RAM
		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		mov	al,[4000h + si]
		pop	ds
		push	bx
		mov	bx,charmap
		xlat
		pop	bx
		call	putc
		inc	bl
		cmp	bl,36
		jb	.col
		pop	cx
		inc	cl
		cmp	cl,24
		jb	.row
		mov	dx,1800h		; row 24
		xchg	dh,dl
		mov	ah,08h
		int	83h
		mov	si,s_frames
		call	puts
		mov	ax,[injected]
		call	puthex16
		mov	si,s_irqs
		call	puts
		mov	ax,[z80_irqs]
		call	puthex16
		mov	si,s_psw
		call	puts
		mov	ax,[last_psw]
		call	puthex16
		mov	si,s_ip
		call	puts
		mov	ax,[last_ip]
		call	puthex16
		mov	si,s_ie0
		call	puts
		mov	ax,[ie0_irqs]
		call	puthex16
		mov	si,s_ie
		call	puts
		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		mov	al,[5000h]
		mov	ah,[4e00h]		; game state: 1 demonstration, 3 playing
		pop	ds
		call	puthex8
		mov	si,s_state
		call	puts
		mov	al,ah
		call	puthex8
		pop	ds
		ret

; [view_x] = arcade column x, BL = arcade row y -> SI = tile RAM offset.
tile_offset:	xor	ah,ah
		mov	al,[view_x]
		cmp	bl,2
		jb	.top
		cmp	bl,34
		jae	.bottom
		mov	si,27			; 40h + (27 - x) * 32 + (y - 2)
		sub	si,ax
		shl	si,5
		add	si,40h - 2
		add	si,bx
		ret
.top:		mov	si,3ddh			; y = 0: 3DDh - x, y = 1: 3FDh - x
		or	bl,bl
		jz	.sub
		mov	si,3fdh
		jmp	.sub
.bottom:	mov	si,1dh			; y = 34: 1Dh - x, y = 35: 3Dh - x
		cmp	bl,34
		je	.sub
		mov	si,3dh
.sub:		sub	si,ax
		ret

; ---------------------------------------------------------------------------
; 320x224 graphics at 15.98 kHz, the display mode planned for the port: the
; sequence of vaeg's tools/pc88va/vtiming/v480pat.asm "224 R W" (SYNC
; 37/224/2/4, 267 lines, 59.9 Hz; docs/modernization/pc88va-video-modes.md
; 12.2). Sixteen colour bars, a white frame on lines 0 and 223 and at dots
; 0-1 and 318-319, and white marks at dots 16 and 303 bounding the rotated
; 288-dot arcade picture. Any key reboots.

video224:	mov	ax,1702h		; clear the text screen
		int	83h
		mov	ah,00h			; graphics: single plane, 4 bits/pixel
		mov	bh,0a0h
		mov	bl,0ah			; 200-line rasters, 320 dots
		mov	cx,0404h
		xor	dx,dx
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	di,desc224
		mov	ax,0100h		; frame buffer 0 of screen 0
		mov	cx,1
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	di,desc224
		mov	ax,0700h		; its address, at desc224 + 6
		mov	cl,0
		int	8fh
		or	ax,ax
		jnz	.fail
		push	cs
		pop	es
		mov	ax,[desc224 + 6]
		mov	dx,[desc224 + 8]
		cmp	dx,000ah
		jae	.cpu
		add	dx,000ah		; GVRAM-relative: GVRAM is at A0000h
.cpu:		mov	[gbase],ax
		mov	[gbase + 2],dx
		cli
		mov	dx,0153h		; system memory area: GVRAM
		in	al,dx
		and	al,0f0h
		or	al,04h
		out	dx,al
		mov	dx,0580h		; single-plane write mode: CPU data
		mov	al,10h
		out	dx,al
		xor	si,si			; SI: line
.line:		mov	ax,160
		mul	si
		add	ax,[gbase]
		adc	dx,[gbase + 2]
		mov	di,ax
		and	di,000fh
		shr	ax,4
		shl	dx,12
		or	ax,dx
		mov	es,ax
		xor	bx,bx			; BX: byte in the line (two dots)
.byte:		mov	ax,bx			; colour bar: 20 dots = 10 bytes
		mov	cl,10
		div	cl
		mov	ah,al
		shl	ah,4
		or	al,ah
		or	si,si
		jz	.white
		cmp	si,223
		je	.white
		or	bx,bx
		jz	.white
		cmp	bx,159
		je	.white
		cmp	bx,8			; dots 16-17
		je	.white
		cmp	bx,151			; dots 302-303
		jne	.put
.white:		mov	al,0ffh
.put:		stosb
		inc	bx
		cmp	bx,160
		jb	.byte
		inc	si
		cmp	si,224
		jb	.line
		push	cs
		pop	es
		sti
		mov	ax,0b01h		; graphics display on
		int	8fh
		mov	ah,16h			; as V480PAT before changing the timing
		int	84h
		mov	ax,0500h		; frame-buffer display set-up (V480PAT)
		mov	cl,00h
		xor	bx,bx
		xor	dx,dx
		int	8fh
		mov	ax,0b01h
		int	8fh
		xor	ax,ax
		mov	dx,010ah
		out	dx,ax
		mov	ax,224
		mov	dx,0206h
		out	dx,ax
		mov	dx,0212h
		out	dx,ax
		mov	si,sync224		; TSP SYNC
		cli
		mov	al,10h
		call	tsp_cmd
		mov	cx,14
.prm:		lodsb
		call	tsp_prm
		loop	.prm
		sti
		call	wait_key
		jmp	0ffffh:0000h		; reboot
.fail:		mov	si,s_vfail
		call	puts
		call	wait_key
		jmp	menu

tsp_cmd:	mov	ah,al
		mov	dx,0142h
.w:		in	al,dx
		test	al,05h
		jnz	.w
		mov	al,ah
		out	dx,al
		ret

tsp_prm:	mov	ah,al
		mov	dx,0142h
.w:		in	al,dx
		test	al,01h
		jnz	.w
		mov	al,ah
		mov	dx,0146h
		out	dx,al
		ret

; ---------------------------------------------------------------------------
; Text output (text BIOS INT 83h) and keyboard (INT 82h)

text_init:	mov	ah,2ah			; initialise the text screen
		int	83h
		mov	ax,1702h		; clear the whole split screen
		int	83h
		xor	dx,dx
		mov	ah,08h
		int	83h
		ret

putc:		pusha
		push	ds
		push	es
		xor	ah,ah
		mov	dx,ax
		int	83h
		pop	es
		pop	ds
		popa
		ret

puts:		push	ax
.l:		mov	al,[cs:si]
		inc	si
		or	al,al
		jz	.r
		call	putc
		jmp	.l
.r:		pop	ax
		ret

crlf:		mov	si,s_crlf
		jmp	puts

puthex16:	push	ax
		mov	al,ah
		call	puthex8
		pop	ax
puthex8:	push	ax
		shr	al,4
		call	.digit
		pop	ax
		and	al,0fh
.digit:		push	ax
		add	al,'0'
		cmp	al,'9'
		jbe	.out
		add	al,7
.out:		call	putc
		pop	ax
		ret

wait_key:	mov	ah,0ch
		int	82h
		mov	ah,09h
		int	82h
		ret

; ---------------------------------------------------------------------------
; Z80 probe snippets (hand-assembled; each ends with DI, RETEM)

z_im1:		db	31h, 00h, 0feh		; ld sp,0FE00h
		db	0edh, 56h		; im 1
		db	3eh, 77h		; ld a,77h
		db	0f3h			; di
		db	0edh, 0fdh		; retem
z_im1_end:

z_index:	db	31h, 00h, 0feh		; ld sp,0FE00h
		db	0ddh, 21h, 30h, 0ffh	; ld ix,0FF30h
		db	0fdh, 21h, 40h, 0ffh	; ld iy,0FF40h
		db	0ddh, 36h, 05h, 0a5h	; ld (ix+5),0A5h
		db	0ddh, 7eh, 05h		; ld a,(ix+5)
		db	0fdh, 77h, 02h		; ld (iy+2),a
		db	0ddh, 23h		; inc ix
		db	01h, 11h, 11h		; ld bc,1111h
		db	0d9h			; exx
		db	01h, 22h, 22h		; ld bc,2222h
		db	0d9h			; exx
		db	0afh			; xor a
		db	0fdh, 7eh, 02h		; ld a,(iy+2)
		db	0ddh, 0e5h		; push ix
		db	0e1h			; pop hl
		db	0fdh, 0e5h		; push iy
		db	0d1h			; pop de
		db	0f3h			; di
		db	0edh, 0fdh		; retem
z_index_end:

z_ldi:		db	31h, 00h, 0feh		; ld sp,0FE00h
		db	3eh, 5ah		; ld a,5Ah
		db	0edh, 47h		; ld i,a
		db	0afh			; xor a
		db	0edh, 57h		; ld a,i
		db	47h			; ld b,a
		db	0f5h			; push af
		db	0e1h			; pop hl     (L = F)
		db	3eh, 00h		; ld a,0
		db	0edh, 47h		; ld i,a
		db	3eh, 0ffh		; ld a,0FFh
		db	0edh, 57h		; ld a,i
		db	4fh			; ld c,a
		db	0f5h			; push af
		db	0d1h			; pop de     (E = F)
		db	0f3h			; di
		db	0edh, 0fdh		; retem
z_ldi_end:

z_speed:	db	31h, 00h, 0feh		; ld sp,0FE00h
		db	0fbh			; ei
		db	2ah, 00h, 0ffh		; ld hl,(COUNTER)
		db	3ah, 00h, 0ffh		; 1: ld a,(COUNTER)
		db	0bdh			; cp l
		db	28h, 0fah		; jr z,1b
		db	47h			; ld b,a
		db	21h, 00h, 00h		; ld hl,0
		db	23h			; 2: inc hl
		db	3ah, 00h, 0ffh		; ld a,(COUNTER)
		db	0b8h			; cp b
		db	28h, 0f9h		; jr z,2b
		db	0f3h			; di
		db	0edh, 0fdh		; retem
z_speed_end:

z_di:		db	31h, 00h, 0feh		; ld sp,0FE00h
		db	0f3h			; di
		db	2ah, 00h, 0ffh		; ld hl,(COUNTER)
		db	1bh			; 1: dec de       (DE: about 4 frames)
		db	7ah			; ld a,d
		db	0b3h			; or e
		db	20h, 0fbh		; jr nz,1b
		db	0edh, 4bh, 00h, 0ffh	; ld bc,(COUNTER)
		db	0fbh			; ei
		db	11h, 64h, 00h		; ld de,100
		db	1bh			; 2: dec de
		db	7ah			; ld a,d
		db	0b3h			; or e
		db	20h, 0fbh		; jr nz,2b
		db	0edh, 5bh, 00h, 0ffh	; ld de,(COUNTER)
		db	0edh, 53h, 04h, 0ffh	; ld (0FF04h),de  (just after EI)
		db	0edh, 5bh, 02h, 0ffh	; ld de,(0FF02h)  (about 2 frames)
		db	1bh			; 3: dec de
		db	7ah			; ld a,d
		db	0b3h			; or e
		db	20h, 0fbh		; jr nz,3b
		db	0f3h			; di
		db	0edh, 5bh, 00h, 0ffh	; ld de,(COUNTER)
		db	0edh, 0fdh		; retem
z_di_end:

z_eiw:		db	31h, 00h, 0feh		; ld sp,0FE00h
		db	2ah, 00h, 0ffh		; ld hl,(COUNTER)
		db	7dh			; ld a,l
		db	0c6h, 03h		; add a,3
		db	47h			; ld b,a
		db	0f3h			; 1: di
		db	0fbh			; ei
		db	3ah, 00h, 0ffh		; ld a,(COUNTER)
		db	0b8h			; cp b
		db	20h, 0f8h		; jr nz,1b
		db	0f3h			; di
		db	0edh, 0fdh		; retem
z_eiw_end:

z_halt:		db	31h, 00h, 0feh		; ld sp,0FE00h
		db	2ah, 00h, 0ffh		; ld hl,(COUNTER)
		db	0fbh			; ei
		db	76h			; halt
		db	0f3h			; di
		db	0edh, 5bh, 00h, 0ffh	; ld de,(COUNTER)
		db	3eh, 55h		; ld a,55h
		db	0edh, 0fdh		; retem
z_halt_end:

z_isr:		db	0f5h			; 0038h: push af
		db	3ah, 10h, 0ffh		; ld a,(0FF10h)
		db	3ch			; inc a
		db	32h, 10h, 0ffh		; ld (0FF10h),a
		db	0f1h			; pop af
		db	0fbh			; ei
		db	0c9h			; ret
z_isr_end:

z_inject:	db	31h, 00h, 0feh		; ld sp,0FE00h
		db	0afh			; xor a
		db	32h, 10h, 0ffh		; ld (0FF10h),a
		db	3eh, 01h		; ld a,1
		db	32h, 00h, 50h		; ld (5000h),a   interrupt enable
		db	01h, 34h, 12h		; ld bc,1234h
		db	11h, 78h, 56h		; ld de,5678h
		db	21h, 0bch, 9ah		; ld hl,9ABCh
		db	0fbh			; ei
		db	3ah, 10h, 0ffh		; 1: ld a,(0FF10h)
		db	0feh, 05h		; cp 5
		db	38h, 0f9h		; jr c,1b
		db	0f3h			; di
		db	0edh, 73h, 20h, 0ffh	; ld (0FF20h),sp
		db	0edh, 0fdh		; retem
z_inject_end:

; ---------------------------------------------------------------------------
; Data

s_title		db	'pc88va-pk M01 feasibility test', 13, 10, 0
s_mask		db	'ICU mask at boot: ', 0
s_menu		db	13, 10, 13, 10
		db	'1  compatible-mode probes', 13, 10
		db	'2  the game in compatible mode (tile RAM as text)', 13, 10
		db	'3  320x224 at 15.98 kHz test pattern (a key reboots)', 13, 10, 0
s_probes	db	'Compatible-mode probes. A probe that never finishes', 13, 10
		db	'hangs on its line: report the last line shown.', 13, 10, 13, 10, 0
s_im1		db	'im1      ', 0
s_index		db	'index    ', 0
s_ldi		db	'ld-i     ', 0
s_speed		db	'speed    ', 0
s_di		db	'di-masks ', 0
s_halt		db	'ei-halt  ', 0
s_eiw		db	'ei-window', 0
s_inject	db	'inject   ', 0
s_pass		db	'PASS ', 0
s_fail		db	'FAIL ', 0
s_a		db	' A=', 0
s_bc		db	' BC=', 0
s_de		db	' DE=', 0
s_hl		db	' HL=', 0
s_sp		db	'         SP after=', 0
s_kept		db	'         VRTC under DI kept=', 0
s_iter		db	'iterations/frame=', 0
s_psw		db	' PSW=', 0
s_frames	db	'inj=', 0
s_ip		db	' PC=', 0
s_ie0		db	' IE0=', 0
s_state		db	' state=', 0
s_ie		db	' 5000h=', 0
s_irqs		db	' irqs=', 0
s_vfail		db	13, 10, 'Graphics BIOS call failed. Press a key.', 13, 10, 0
s_done		db	13, 10, 'Done. Press a key for the menu.', 13, 10, 0
s_crlf		db	13, 10, 0

; Tile code -> character: letters and digits as ASCII, 40h blank, 10h-13h
; small items, 14h-17h large items, other codes below 80h '?', the rest '#'.
charmap:
%assign c 0
%rep 256
 %if c == 40h
		db	' '
 %elif (c >= 30h && c <= 39h) || (c >= 41h && c <= 5ah)
		db	c
 %elif c >= 10h && c <= 13h
		db	'.'
 %elif c >= 14h && c <= 17h
		db	'o'
 %elif c < 80h
		db	'?'
 %else
		db	'#'
 %endif
 %assign c c + 1
%endrep

; SYNC: 15.98 kHz, TBL 37, 224 active lines, bottom 2, sync 4
sync224		db	0c1h, 57h, 1ch, 00h, 9fh, 00h, 10h, 0fh, 25h, 00h, 0e0h, 00h, 02h, 04h
		align	2
desc224		dw	4, 320, 224, 0, 0, 0
gbase		dd	0
old_vrtc	dd	0
old_mask	db	0
old_mask_ir2	db	0
chain		db	0
in_z80		db	0
inject		db	0
pac_mode	db	0
view_x		db	0
r_a		db	0
		align	2
frames		dw	0
z80_irqs	dw	0
injected	dw	0
yield_at	dw	0
last_psw	dw	0
last_ip		dw	0
ie0_irqs	dw	0
main_sp		dw	0
z80_sp		dw	0
speed		dw	0
r_bc		dw	0
r_de		dw	0
r_hl		dw	0
r_sp		dw	0

end_of_program:
		times	ROM_OFFSET - ($ - $$) db 0	; fails if the program is too large
