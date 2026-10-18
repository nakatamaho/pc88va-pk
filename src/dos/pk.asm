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
; PK.COM: ROM loader for the PC-88VA game port, under MS-DOS
; (docs/DESIGN.md).
;
;   PK [/D] [directory]
;
; The program holds no data from the arcade ROMs. It looks in the
; directory, by default the current one, for the eight ROM files it needs,
; recognised by size and CRC-32 whatever their names, and builds in memory
; what tools/build.py puts on the self-booting disk: the patched Z80
; program (tools/patches.py), the tile and sprite rows, the colour lookup
; and the palette (tools/gfx.py). It then starts the game code
; (src/game/pk.asm, assembled with NO_FM: SSG sound only) and never
; returns: ESC in the game restarts the machine. /D writes the built
; payload to PAYLOAD.BIN and returns to DOS instead (for checking the
; build).
;
; Memory: the payload is built at LOAD_SEG:0000-E7FF (3000h; MS-DOS 4.0
; loads programs at 1DDBh on the PC-88VA), the ROM files are read to the
; segment after it, and the game (assembled with the same LOAD_SEG) uses
; LOAD_SEG to LOAD_SEG + 3080h and GVRAM. The program therefore has to end
; below LOAD_SEG, and DOS has to leave memory up to LOAD_SEG + 3080h to it.
; SGP_CACHE adds 24 KiB at LOAD_SEG + 3100h, ending at + 3700h.
;
; dosdata.inc (written by tools/build_dos.py) defines LOAD_SEG, GAME_BIN,
; the input read sites, the palette levels and SCREEN_OFFS_BIN.

		cpu	186
		org	100h

SCRATCH		equ	PAY + 1000h	; the ROM files as read (the game's
					; Z80 segment)
S_PROGRAM	equ	0000h		; the four program ROMs
S_TILES		equ	4000h		; tile ROM
S_SPRITES	equ	5000h		; sprite ROM
S_COLOURS	equ	6000h		; colour PROM
S_LOOKUP	equ	6100h		; colour lookup PROM
S_WAVES		equ	6200h
S_TEMP		equ	8000h		; a file being checked
S_PROGRAM_B	equ	9000h		; the program ROMs of version B
PAY		equ	LOAD_SEG	; the payload, as on the self-booting disk
P_PROGRAM	equ	4000h
P_TILES		equ	8000h
P_LOOKUP	equ	9000h
P_PALETTE	equ	9080h
P_SCREEN_OFFS	equ	9100h
P_FM_READY	equ	9f01h
P_FM_VOICES	equ	9900h
P_KIND		equ	9f00h		; program version for the game: 0 A, 1 B
P_SPRITES	equ	0a000h
PAYLOAD_BYTES	equ	0e800h
%ifdef SGP_CACHE
MEMORY_TOP	equ	PAY + 3700h	; 24 KiB sprite cache at PAY + 3100h
%else
MEMORY_TOP	equ	PAY + 3080h	; paragraphs the game needs
%endif

start:		mov	sp,stack_top
		cld
		mov	dx,s_banner
		call	print
		mov	dx,01cbh		; 15 kHz only: port 1CBh bit 3 is 1 at
		in	al,dx			; 24.8 kHz (technical manual 4.9.2)
		test	al,08h
		jz	.khz15
		mov	dx,s_24khz
		jmp	fail
.khz15:
		mov	ax,stack_top		; the program must end below 2000h
		add	ax,15
		shr	ax,4
		mov	bx,cs
		add	ax,bx
		cmp	ax,PAY
		ja	.low
		cmp	word [0002h],MEMORY_TOP	; and DOS leave memory to 7500h
		jae	.memory
.low:		mov	dx,s_memory
		call	print
		mov	ax,cs			; show where DOS put the program
		call	print_hex
		mov	dx,s_top
		call	print
		mov	ax,[0002h]
		call	print_hex
		mov	dx,s_rom_end
		jmp	fail
.memory:	call	parse
		call	crc_init
		call	shuffle_init
		call	scan
		mov	al,1			; the shared ROMs, and one complete
		call	missing			; program (version A, else B)
		jc	.bad
		mov	byte [kind],0
		mov	al,0
		call	missing
		jnc	.build
		push	si			; SI: version A's first missing
		mov	byte [kind],1
		mov	al,2
		call	missing
		pop	ax
		jnc	.build
		mov	si,ax			; neither: report version A's
.bad:		mov	dx,s_rom		; the first one missing
		call	print
		mov	ax,[si + 6]
		call	print_hex
		mov	ax,[si + 4]
		call	print_hex
		mov	dx,s_rom_size
		call	print
		mov	ax,[si + 2]
		call	print_hex
		mov	dx,s_rom_end
		call	print
		mov	dx,s_need
		jmp	fail
.build:		call	build
%ifdef DOS_FM
		call	fm_prepare
%endif
		cmp	byte [debug],0
		jne	write_payload
		cli
		jmp	PAY:0000h

write_payload:	mov	dx,s_payload
		mov	ah,3ch			; create
		xor	cx,cx
		int	21h
		jc	.err
		mov	bx,ax
		push	ds
		mov	ax,PAY
		mov	ds,ax
		xor	dx,dx
		mov	cx,PAYLOAD_BYTES
		mov	ah,40h			; write
		int	21h
		pop	ds
		jc	.err
		cmp	ax,PAYLOAD_BYTES
		jne	.err
		mov	ah,3eh
		int	21h
		mov	dx,s_written
		call	print
		mov	ax,4c00h
		int	21h
.err:		mov	dx,s_write_err
fail:		call	print
		mov	ax,4c01h
		int	21h

; ---------------------------------------------------------------------------
; Command tail: /D, and a directory that prefixes the file names.

parse:		mov	si,81h
		mov	di,path
.skip:		lodsb
		cmp	al,' '
		je	.skip
		cmp	al,9
		je	.skip
		cmp	al,0dh
		je	.end
		cmp	al,'/'
		jne	.word
		lodsb
		and	al,0dfh
		cmp	al,'S'
		jne	.not_ssg
		mov	byte [force_ssg],1
		jmp	.skip
.not_ssg:	cmp	al,'F'
		jne	.not_force
		mov	byte [force_fm],1
		jmp	.skip
.not_force:	cmp	al,'D'
		jne	.skip
		mov	byte [debug],1
		jmp	.skip
.word:		cmp	di,path + 114
		jae	.end
		stosb				; the directory
		lodsb
		cmp	al,' '
		je	.sep
		cmp	al,9
		je	.sep
		cmp	al,0dh
		je	.sep
		jmp	.word
.sep:		dec	si
		mov	al,[di - 1]
		cmp	al,'\'
		je	.skip
		cmp	al,':'
		je	.skip
		mov	al,'\'
		stosb
		jmp	.skip
.end:		mov	[path_end],di
		ret

; CF = 1 and SI = the first ROM of group AL (0 version A, 1 shared, 2
; version B) not found; CF = 0 if all are.
missing:	mov	si,roms
.e:		cmp	word [si],0ffffh
		je	.all
		cmp	[si + 9],al
		jne	.n
		cmp	byte [si + 8],0
		je	.no
.n:		add	si,ROM_ENTRY
		jmp	.e
.all:		clc
		ret
.no:		stc
		ret

; Look at every file in the directory: one of the size of a ROM not yet
; found is read to S_TEMP; if its CRC-32 is that of a ROM of that size not
; yet found, it is copied to the ROM's place in SCRATCH and marked found.
scan:		mov	ah,1ah			; disk transfer area
		mov	dx,dta
		int	21h
		mov	di,[path_end]		; path = directory + *.*
		mov	si,s_wild
.w:		lodsb
		stosb
		or	al,al
		jnz	.w
		mov	dx,path
		xor	cx,cx			; normal files
		mov	ah,4eh			; find first
		int	21h
		jc	.done
.file:		cmp	word [dta + 1ch],0	; size: high word
		jne	.next
		mov	ax,[dta + 1ah]
		mov	si,roms			; a ROM of this size not yet found?
.size:		cmp	word [si],0ffffh
		je	.next
		cmp	byte [si + 8],0
		jne	.snext
		cmp	ax,[si + 2]
		je	.read
.snext:		add	si,ROM_ENTRY
		jmp	.size
.read:		mov	di,[path_end]		; path = directory + the name
		mov	si,dta + 1eh
.n:		lodsb
		stosb
		or	al,al
		jnz	.n
		mov	dx,path
		mov	ax,3d00h		; open for reading
		int	21h
		jc	.next
		mov	bx,ax
		mov	cx,[dta + 1ah]
		push	ds
		mov	ax,SCRATCH
		mov	ds,ax
		mov	dx,S_TEMP
		mov	ah,3fh
		int	21h
		pop	ds
		pushf
		push	ax
		mov	ah,3eh
		int	21h
		pop	ax
		popf
		jc	.next
		cmp	ax,[dta + 1ah]
		jne	.next
		mov	cx,ax			; DX:AX = its CRC-32
		push	ds
		mov	si,SCRATCH
		mov	ds,si
		mov	si,S_TEMP
		call	crc32
		pop	ds
		mov	si,roms
.match:		cmp	word [si],0ffffh
		je	.next
		cmp	byte [si + 8],0
		jne	.mnext
		mov	bx,[dta + 1ah]
		cmp	bx,[si + 2]
		jne	.mnext
		cmp	ax,[si + 4]
		jne	.mnext
		cmp	dx,[si + 6]
		jne	.mnext
		mov	byte [si + 8],1		; found: to its place
		mov	cx,bx
		mov	di,[si]
		push	ds
		push	es
		mov	ax,SCRATCH
		mov	ds,ax
		mov	es,ax
		mov	si,S_TEMP
		rep	movsb
		pop	es
		pop	ds
		jmp	.next
.mnext:		add	si,ROM_ENTRY
		jmp	.match
.next:		mov	ah,4fh			; find next
		int	21h
		jnc	.file
.done:		ret

; ---------------------------------------------------------------------------
; CRC-32 (IEEE, reflected 0EDB88320h): DX:AX = CRC of CX bytes at DS:SI.

crc_init:	mov	di,crc_table
		xor	bx,bx
.n:		xor	dx,dx
		mov	ax,bx
		mov	cx,8
.bit:		shr	dx,1
		rcr	ax,1
		jnc	.next
		xor	ax,8320h
		xor	dx,0edb8h
.next:		loop	.bit
		stosw
		mov	ax,dx
		stosw
		inc	bx
		cmp	bx,256
		jb	.n
		ret

crc32:		mov	ax,0ffffh
		mov	dx,ax
		jcxz	.done
.byte:		mov	bl,[si]
		inc	si
		xor	bl,al
		xor	bh,bh
		shl	bx,2
		mov	al,ah			; CRC >> 8
		mov	ah,dl
		mov	dl,dh
		xor	dh,dh
		xor	ax,[cs:crc_table + bx]
		xor	dx,[cs:crc_table + bx + 2]
		loop	.byte
.done:		not	ax
		not	dx
		ret

; ---------------------------------------------------------------------------
; Tables: shuffle[b] = the 4 pixels of a ROM graphics byte (pixel j has its
; high bit at bit 7 - j and its low bit at bit 3 - j) as 2-bit fields, the
; leftmost in the top bits (tools/gfx.py _pixels and _pack); reverse[b] =
; the 4 fields of b in the opposite order.

shuffle_init:	xor	bx,bx
.b:		xor	dl,dl			; DL: shuffle, DH: reverse
		xor	dh,dh
		mov	cx,4			; pixel j = 4 - CX
.j:		mov	al,bl
		mov	ah,4
		sub	ah,cl			; AH: j
		push	cx
		mov	cl,7
		sub	cl,ah
		shr	al,cl			; high bit
		and	al,1
		shl	al,1
		mov	ah,bl
		sub	cl,4
		shr	ah,cl			; low bit
		and	ah,1
		or	al,ah
		shl	dl,2
		or	dl,al
		pop	cx
		loop	.j
		mov	[shuffle + bx],dl
		mov	al,bl			; reverse: fields 0-3 swapped
		mov	cx,4
.r:		shl	dh,2
		mov	ah,al
		and	ah,3
		or	dh,ah
		shr	al,2
		loop	.r
		mov	[reverse + bx],dh
		inc	bx
		cmp	bx,256
		jb	.b
		ret

; ---------------------------------------------------------------------------
; Build the payload at PAY:0000 from the ROM files in SCRATCH.

build:		mov	ax,PAY			; zero it, then the game code
		mov	es,ax
		xor	di,di
		xor	ax,ax
		mov	cx,PAYLOAD_BYTES / 2
		rep	stosw
		xor	di,di
		mov	si,game_bin
		mov	cx,GAME_BYTES / 2
		rep	movsw
		mov	si,screen_offs		; our own tables
		mov	di,P_SCREEN_OFFS
		mov	cx,800h / 2
		rep	movsw
		push	ds
		mov	ax,SCRATCH
		mov	ds,ax
		xor	si,si			; the program, A or B
		cmp	byte [cs:kind],0
		je	.a
		mov	si,S_PROGRAM_B
.a:		mov	di,P_PROGRAM
		mov	cx,4000h / 2
		rep	movsw
		call	patch
		call	tiles
		call	lookup
		call	palette
		call	sprites
		pop	ds
		ret

; The patches of tools/patches.py (DS = SCRATCH, ES = PAY).
patch:		mov	si,input_sites		; LD A,(50xxh) -> LD A,(51xxh)
.site:		mov	bx,[cs:si]
		or	bx,bx
		jz	.halt
		mov	byte [es:P_PROGRAM + bx + 2],51h
		add	si,2
		jmp	.site
.halt:		mov	al,[cs:kind]
		mov	[es:P_KIND],al
		or	al,al
		jnz	.b
		push	ds			; A: EI; HALT at 2349h -> EI; JR $:
		push	es			; the 8 bytes from 2341h move to
		pop	ds			; 233Dh
		mov	si,P_PROGRAM + 2341h
		mov	di,P_PROGRAM + 233dh
		mov	cx,8
		rep	movsb
		push	cs
		pop	ds
		mov	si,halt_tail
		mov	cx,6
		rep	movsb
		pop	ds
		mov	cx,4			; checksum: all four blocks
		jmp	.sums
.b:		mov	si,b_patches		; B: IM 1, LD I,A, the start-up
.bp:		mov	bx,[cs:si]		; wait (tools/patches.py)
		or	bx,bx
		jz	.bstart
		mov	al,[cs:si + 2]
		mov	[es:P_PROGRAM + bx],al
		add	si,3
		jmp	.bp
.bstart:	mov	si,b_start
		mov	di,P_PROGRAM + B_START_AT
		mov	cx,B_START_BYTES
.bs:		mov	al,[cs:si]
		stosb
		inc	si
		loop	.bs
		mov	cx,3			; checksum: the test stops at 3000h
.sums:		mov	bx,P_PROGRAM		; checksum compensation: in each
.block:		xor	dx,dx			; tested 4 KiB block the even and
		xor	si,si			; the odd bytes sum to 0
.sum:		add	dl,[es:bx + si]
		add	dh,[es:bx + si + 1]
		add	si,2
		cmp	si,1000h
		jb	.sum
		sub	[es:bx + 0ffeh],dl
		sub	[es:bx + 0fffh],dh
		add	bx,1000h
		loop	.block
		ret

; Tile rows (DS = SCRATCH, ES = PAY): tile t row y = shuffle of bytes
; t * 16 + 8 + y, then t * 16 + y.
tiles:		mov	si,S_TILES
		mov	di,P_TILES
		mov	bx,shuffle
.tile:		xor	dx,dx			; DX: row
.row:		push	si
		add	si,dx
		mov	al,[si + 8]
		cs xlatb
		stosb
		mov	al,[si]
		cs xlatb
		stosb
		pop	si
		inc	dx
		cmp	dx,8
		jb	.row
		add	si,16
		cmp	si,S_TILES + 1000h
		jb	.tile
		ret

lookup:		mov	si,S_LOOKUP
		mov	di,P_LOOKUP
		mov	cx,128
.b:		lodsb
		and	al,0fh
		stosb
		loop	.b
		ret

; The 16 colours as PC-88VA palette words (tools/gfx.py palette): R bits
; 0-2 and G bits 3-5 through LEVEL3, B bits 6-7 through LEVEL2.
palette:	mov	si,S_COLOURS
		mov	di,P_PALETTE
		mov	cx,16
		xor	bh,bh
.c:		lodsb
		mov	dl,al
		xor	bp,bp
		mov	bl,dl			; G: bits 15-12, unused bits 11-10
		shr	bl,3
		and	bl,7
		mov	al,[cs:level3 + bx]
		or	al,al
		jz	.r
		xor	ah,ah
		shl	ax,12
		or	ax,0c00h
		or	bp,ax
.r:		mov	bl,dl			; R: bits 9-6, unused bit 5
		and	bl,7
		mov	al,[cs:level3 + bx]
		or	al,al
		jz	.b
		xor	ah,ah
		shl	ax,6
		or	ax,20h
		or	bp,ax
.b:		mov	bl,dl			; B: bits 4-1, unused bit 0
		shr	bl,6
		mov	al,[cs:level2 + bx]
		or	al,al
		jz	.w
		xor	ah,ah
		shl	ax,1
		or	ax,1
		or	bp,ax
.w:		mov	ax,bp
		stosw
		loop	.c
		ret

; Sprite rows (DS = SCRATCH, ES = PAY), as tools/gfx.py sprite_rows: for
; each code and horizontal flip, 16 rows of 4 bytes (16 pixels) and 5 bytes
; (the row one pixel to the right). Row y of code c is the shuffle of the
; bytes at c * 64 + (8, 16, 24, 0) + (y < 8 ? y : y + 24).
sprites:	mov	si,S_SPRITES
		mov	di,P_SPRITES
.code:		push	di			; the 16 rows to row_buf
		mov	di,row_buf
		xor	dx,dx			; DX: row
.r:		mov	bx,dx
		cmp	bx,8
		jb	.lo
		add	bx,24
.lo:		add	bx,si
		mov	al,[bx + 8]
		call	.put
		mov	al,[bx + 16]
		call	.put
		mov	al,[bx + 24]
		call	.put
		mov	al,[bx]
		call	.put
		inc	dx
		cmp	dx,16
		jb	.r
		pop	di
		xor	bp,bp			; BP: flip
.flip:		push	si
		mov	si,row_buf
		mov	cx,16
.row:		mov	al,[cs:si]		; the 4 bytes, flipped or not
		mov	ah,[cs:si + 1]
		mov	dl,[cs:si + 2]
		mov	dh,[cs:si + 3]
		or	bp,bp
		jz	.even
		push	bx			; flipped: AL AH DL DH =
		mov	bx,reverse		; reversed DH DL AH AL
		xchg	al,dh
		cs xlatb			; AL = rev(old DH)
		xchg	al,dh
		cs xlatb			; AL = rev(old AL)
		xchg	al,dh			; AL = e0, DH = e3
		xchg	ah,dl
		xchg	al,ah
		cs xlatb			; rev(old DL)
		xchg	al,ah			; AH = e1
		xchg	al,dl
		cs xlatb			; rev(old AH)
		xchg	al,dl			; DL = e2
		pop	bx
.even:		stosb				; AL AH DL DH
		xchg	al,ah
		stosb
		xchg	al,ah
		push	ax
		mov	al,dl
		stosb
		mov	al,dh
		stosb
		pop	ax
		mov	bl,al			; one pixel right: 5 bytes
		shr	bl,2
		mov	[es:di],bl
		mov	bl,al
		shl	bl,6
		mov	bh,ah
		shr	bh,2
		or	bl,bh
		mov	[es:di + 1],bl
		mov	bl,ah
		shl	bl,6
		mov	bh,dl
		shr	bh,2
		or	bl,bh
		mov	[es:di + 2],bl
		mov	bl,dl
		shl	bl,6
		mov	bh,dh
		shr	bh,2
		or	bl,bh
		mov	[es:di + 3],bl
		mov	bl,dh
		shl	bl,6
		mov	[es:di + 4],bl
		add	di,5
		add	si,4
		dec	cx
		jz	.rows_done
		jmp	.row
.rows_done:	pop	si
		inc	bp
		cmp	bp,2
		jb	.flip
		add	si,64
		cmp	si,S_SPRITES + 1000h
		jb	.code
		ret
.put:		push	bx
		mov	bx,shuffle
		cs xlatb
		pop	bx
		mov	[cs:di],al
		inc	di
		ret

; AX in hexadecimal.
print_hex:	mov	cx,4
.d:		rol	ax,4
		push	ax
		and	al,0fh
		add	al,'0'
		cmp	al,'9'
		jbe	.o
		add	al,7
.o:		mov	dl,al
		mov	ah,02h
		int	21h
		pop	ax
		loop	.d
		ret

print:		mov	ah,09h
		int	21h
		ret

; ---------------------------------------------------------------------------
; Data

%ifdef DOS_FM
%include "fm.asm"
%endif

ROM_ENTRY	equ	10		; offset, size, CRC-32, found, group
%macro ROM 4
		dw	%1, %2
		dd	%3
		db	0, %4
%endmacro
roms:		ROM	S_PROGRAM, 1000h, 0fee263b3h, 0		; version A
		ROM	S_PROGRAM + 1000h, 1000h, 039d1fc83h, 0
		ROM	S_PROGRAM + 2000h, 1000h, 002083b03h, 0
		ROM	S_PROGRAM + 3000h, 1000h, 07a36fe55h, 0
		ROM	S_TILES, 1000h, 00c944964h, 1		; shared
		ROM	S_SPRITES, 1000h, 0958fedf9h, 1
		ROM	S_COLOURS, 32, 02fc650bdh, 1
		ROM	S_LOOKUP, 256, 03eb3a8e4h, 1
		ROM	S_PROGRAM_B, 1000h, 0c1e6ab10h, 2	; version B
		ROM	S_PROGRAM_B + 1000h, 1000h, 01a6fb2d4h, 2
		ROM	S_PROGRAM_B + 2000h, 1000h, 0bcdd1bebh, 2
		ROM	S_PROGRAM_B + 3000h, 1000h, 0817d94e3h, 2
wave_rom:	ROM	S_WAVES, 256, 0a9cc86bfh, 3
		dw	0ffffh

halt_tail	db	0fbh, 18h, 0feh, 0, 0, 0	; EI; JR $; 3 x NOP

%include "dosdata.inc"

s_banner	db	'Game for the PC-88VA (ROM loader)', 13, 10, '$'
s_memory	db	'Not enough free memory, or the program is loaded too '
		db	'high.', 13, 10, 'Program segment $'
s_top		db	', memory top $'
s_24khz		db	'The machine is running at 24 kHz. This game needs 15 kHz', 13, 10
		db	'(320x224, 15.98 kHz) and a monitor that accepts it.', 13, 10
		db	'Restart the PC-88VA in 15 kHz mode (CRT mode: DIP switch '
		db	'SW1 off).', 13, 10, '$'
s_rom		db	'ROM file not found: CRC-32 $'
s_rom_size	db	', size $'
s_rom_end	db	'h', 13, 10, '$'
s_need		db	'Copy the ROM files listed in PK.TXT to this disk.', 13, 10, '$'
s_wild		db	'*.*', 0
s_payload	db	'PAYLOAD.BIN', 0
s_written	db	'PAYLOAD.BIN written.', 13, 10, '$'
s_write_err	db	'Cannot write PAYLOAD.BIN.', 13, 10, '$'

		align	2
screen_offs:	incbin	SCREEN_OFFS_BIN
		align	2
game_bin:	incbin	GAME_BIN
GAME_BYTES	equ	$ - game_bin

debug		db	0
force_ssg	db	0
force_fm	db	0
kind		db	0		; 0 version A, 1 version B
		align	2
path_end	dw	0

; Uninitialised
		absolute $
		alignb	2
path		resb	128
dta		resb	64
crc_table	resd	256
shuffle		resb	256
reverse		resb	256
row_buf		resb	64
fm_final_path	resb	128
fm_harmonics	resw	15
fm_selected	resw	4
fm_muls		resw	4
fm_wave_at	resw	1
fm_dest		resw	1
fm_real		resw	1
fm_imag		resw	1
fm_sample	resw	1
fm_power	resd	1
fm_total	resw	1
		resb	512
stack_top:
