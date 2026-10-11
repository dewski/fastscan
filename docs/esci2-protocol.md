# Epson FF-680W network scanning protocol

How a Mac drives an Epson FastFoto FF-680W over Wi-Fi, as observed on the wire. FastScan's scanner client is written from this document.

## Sources and rules

Everything here comes from packet captures of Epson ScanSmart driving an FF-680W (firmware `ADF 18P4`), taken on 2026-10-09:

| Capture | What ScanSmart did |
|---|---|
| One-sided, 300 dpi | Scanned two sheets |
| Settings | Opened its scanner settings window, changed the resolution, closed it |
| Two-sided, 600 dpi | Scanned three sheets (two captures: one with the opening, one with the image stream and the end) |
| "Grayscale", two-sided, 600 dpi | Scanned with ScanSmart's grayscale option. The scanner was still asked for color |
| Two-sided, 600 dpi, complete | Scanned four sheets, captured with `tcpdump` with no packets dropped |
| Cancel before data, two-sided, 600 dpi | Pressed Cancel about 7.5 seconds after `TRDT`, before any image data arrived. Captured with `tcpdump` with no packets dropped |
| Cancel during data, two-sided, 600 dpi | Pressed Cancel about 24 seconds after `TRDT`, partway through the second sheet's front. Captured with `tcpdump` with no packets dropped |
| Double feed, two-sided, 600 dpi | Fed four sheets. The fourth was folded and went in crooked, which set off double-feed detection. Captured with `tcpdump` with no packets dropped |
| Paper jam, two-sided, 600 dpi | Fed four sheets and held the third back by its trailing edge as it started to feed. Captured with `tcpdump` with no packets dropped, over a poor Wi-Fi link (31 retransmitted segments) |
| Uncleared jam | Started a scan right after the paper-jam capture, before opening and closing the scanner. Captured with `tcpdump` with no packets dropped |
| Cover opened, two-sided, 600 dpi (three captures) | Opened the scanner's cover as the third sheet started: once with four sheets loaded, and twice with three, so only one sheet was left to fall. ScanSmart showed its double-feed message both times. Captured with `tcpdump` with no packets dropped |
| Scanner's Stop button, two-sided, 600 dpi | Fed three sheets and pressed the red button on the scanner near the end of the second sheet. ScanSmart stopped and closed its preview. Captured with `tcpdump` with no packets dropped |
| FastScan's client: jam, then Scan the Rest | FastScan's own client, one-sided pages two-sided at 300 dpi: a sheet held back until `PJ`, four retries before clearing, then the rest after clearing. Captured with `tcpdump` with no packets dropped |
| Lock held | A script on the Mac opened a connection and locked the scanner, then a second connection from the same Mac opened while it was held. Only greeting, lock and unlock packets were sent; read from the socket, not `tcpdump` |
| Scan button, wrong address | ScanSmart open and idle, the scanner's start button pressed, on a Mac with two addresses on the scanner's network (Ethernet 192.168.3.195, Wi-Fi 192.168.0.95). Nothing scanned. Captured on Ethernet with `tcpdump`, all ports |
| Scan button | The same with Wi-Fi off, so the Mac had one address. ScanSmart scanned the stack. Captured with `tcpdump`, all ports, no packets dropped |
| FastScan's client: scan button | FastScan's own client answering the button, four presses, changing one thing at a time (below). Captured with `tcpdump`, all ports, no packets dropped |

This document records only what was observed and what it implies. Where a meaning is a guess, it says so. It contains no code from any other scanner driver, and code written from it must not consult one.

Byte values are hex. "Host" is the Mac. "Scanner" is the FF-680W.

## Discovery

The scanner advertises `_scanner._tcp` over Bonjour, with TXT records including `ty=EPSON FF-680W`, `mfg=EPSON`, `mdl=FF-680W`, and `scannerAvailable=1`. The service's port is 1865. It does not advertise eSCL (`_uscan._tcp`), and `/eSCL/ScannerCapabilities` returns 404.

ScanSmart also sends SNMP queries (UDP 161, Epson's enterprise OIDs under `1.3.6.1.4.1.1248`, every 15 seconds while it's open) and a UDP exchange on port 3289. Scanning doesn't need either. The scanner's start button uses port 2968 instead (see "Scanning from the scanner's button").

## Transport

One TCP connection to port 1865 carries the whole session.

ScanSmart first opens a connection and sends a TLS ClientHello. The scanner answers with its normal plain greeting (below), not TLS, and ScanSmart drops that connection and opens a second, plain one. A client can skip the TLS attempt.

## Packets

Every message in both directions is a packet with a 12-byte header followed by a payload.

| Bytes | Meaning |
|---|---|
| 0–1 | `49 53`, ASCII `IS` |
| 2–3 | Packet type, big-endian (table below) |
| 4 | `00` from the host, `38` from the scanner |
| 5 | `0C`, the header length |
| 6–9 | Payload length in bytes, big-endian |
| 10–11 | `00 00` |

| Type | Direction | Use |
|---|---|---|
| `80 00` | scanner → host | Greeting, sent as soon as the connection opens |
| `21 00` | host → scanner | Lock |
| `A1 00` | scanner → host | Lock reply |
| `21 01` | host → scanner | Unlock |
| `23 00` | host → scanner | Job request, after a button press (see "Scanning from the scanner's button") |
| `A3 00` | scanner → host | Job reply |
| `A1 01` | scanner → host | Unlock reply, empty payload |
| `20 00` | host → scanner | Request (carries a data header, below) |
| `A0 00` | scanner → host | Reply to a `20 00` request |

Each reply's type is the request's type with the top bit set. Every host packet gets exactly one reply packet. The reply's payload length is in its own header.

### Requests (`20 00`)

A request's payload starts with an 8-byte data header, then the bytes to deliver to the scanner:

| Bytes | Meaning |
|---|---|
| 0–3 | Length of the bytes that follow, big-endian |
| 4–7 | Length of the reply the host expects, big-endian |

The packet header's length field counts the data header too, so a request carrying 12 bytes has a payload length of 20 (`00 00 00 14`).

A request carrying no bytes, only asking for a reply, has the data header `00 00 00 00` followed by the reply length.

## Session

### Opening

1. **Greeting.** The scanner sends a `80 00` packet with the 5-byte payload `01 04 00 00 00`. Meaning unknown. While another connection holds the lock, the greeting is different, and the scanner closes the connection straight after it, before the host sends anything: the 12-byte payload `01 04 81 00 01 01 00 04 C0 A8 03 C3`. Byte 2 is `81` instead of `00`, and the last four bytes read as the IPv4 address 192.168.3.195. That was the Mac holding the lock and also the one connecting, so which of the two it names isn't known. The rest of the payload's meaning is unknown. After a button press reserved the scanner for another address, the greeting was the 3-byte payload `01 04 82`, and again the scanner closed the connection straight after it (see "Scanning from the scanner's button").
2. **Lock.** The host sends a `21 00` packet with the 7-byte payload `01 A0 04 00 00 01 2C`. The scanner replies `A1 00` with the payload `06`. The last two bytes are 300 in decimal; whether that's a timeout is unconfirmed. The short job sessions after a button press lock with `01 A0 04 00 00 00 1E` instead, ending in 30, which fits the timeout reading.
3. **Mode byte.** The host sends a two-byte request, `1C` followed by a letter, expecting a 1-byte reply. The scanner replies `06`. `1C` is the ASCII "file separator" control character.

ScanSmart uses three mode bytes:

| Bytes | When ScanSmart sends it | Effect observed |
|---|---|---|
| `1C 59` (`FS Y`) | Right after locking, and before each status check while waiting | `INFO` and `CAPA` return the scanner's capabilities |
| `1C 5A` (`FS Z`) | Before reading maintenance information | `INFO` and `CAPA` return maintenance data instead |
| `1C 58` (`FS X`) | Immediately before starting a scan | Precedes `STAT`, `PARA` and `TRDT` for the scan |

### Closing

The host sends `FIN` (below), then an unlock packet (`21 01`, empty payload). The scanner replies `A1 01` with an empty payload and closes the connection.

## Commands

Within the mode, the host sends four-letter commands. Each is a 12-byte ASCII request block: the command (letters, padded with a space to four characters), `x`, and seven hex digits giving the length of a parameter block that follows (`0000000` when there is none). Examples: `INFOx0000000`, `IMG x0000000`, `PARAx00003E8`. Both ScanSmart and the scanner write the hex digits in uppercase.

**Without parameters**, the host sends the request block expecting a 64-byte reply.

**With parameters**, the host sends the request block expecting a 0-byte reply, and the scanner answers with an empty reply. Then the host sends the parameter block, expecting a 64-byte reply.

**The 64-byte reply block** starts with the same command, `x`, and seven hex digits, then tokens, padded with `#---`. The hex digits give the length of a data block that the scanner is holding for the host. `INFOx0000124` means 0x124 = 292 bytes are waiting.

**Fetching a data block:** when the length is nonzero, the host sends a request with no bytes, expecting exactly that many, and the scanner replies with the data block. ScanSmart always asks for the exact announced length.

### Tokens

Reply blocks, data blocks and parameter blocks are made of tokens: `#`, a three-character name, then a value that runs until the next `#` (or the end of the block, or a `00` byte in a reply block). Values are built from these fields, often back to back:

| Field | Form | Example |
|---|---|---|
| Short decimal | `d` + 3 digits | `d300` |
| Long decimal | `i` + 7 digits | `i0002550` |
| Hex | `x` + 7 hex digits | `xFFFFFFF` |
| Byte string | `h` + 3 hex digits of length, then that many raw bytes, then `00` bytes up to a multiple of four | `h007FF-680W` and one `00` |
| Words | Four characters, space padded | `JPG `, `OFF ` |

The padding after a byte string was seen in both directions: one `00` after `#PRDh007FF-680W` and two after the 10-byte serial number in `INFO`, and three after the 9-byte color matrix in `PARA`. Byte strings already a multiple of four long (`#VERh008`, `#PRVh00C`, the 256-byte gamma tables) had none.

A token can take several fields, as in `#ACQi0000000i0000000i0002550i0010800`. Raw bytes in an `h` field can contain any value, including `#`, so a parser must use the length.

### `INFO`, device information

After `FS Y`, the data block (292 bytes from this scanner) describes the device. Readings marked "probably" are guesses from the names and values; scanning doesn't depend on them.

| Token | FF-680W value | Reading |
|---|---|---|
| `#ADFTYPEFEED` | | Probably a sheet-fed feeder |
| `#ADFDPLX1SCN` | | Probably two-sided in one pass, which fits the image stream |
| `#ADFFORDPF1N` | | Unknown |
| `#ADFALGNCNTR` | | Probably center-aligned paper |
| `#ADFAREA` | `d850i0001550` | Probably the standard area, 8.50 × 15.50 in, in 1/100 in like `EXI` |
| `#ADFAMIN` | `d200d200` | Probably the minimum paper size, 2.00 × 2.00 in |
| `#ADFAMAX` | `d850i0024000` | Probably the maximum paper size, 8.50 × 240.00 in |
| `#ADFRESO` | `d600` | Probably the maximum resolution |
| `#PRD` | `h007FF-680W` | Product name |
| `#VER` | `h008ADF 18P4` | Firmware |
| `#S/N` | `h00A…` | Serial number |
| `#EXI` | | The `EXI` command is available |

Other tokens seen without a known meaning: `#ADFPREF`, `#ADFASCN`, `#ADFRCVR`, `#ADFOVSNd000d000`, `#ADFCRST`, `#ADFCARD`, `#IMXi0065535i0065535`, `#PRVh00C18.61.SP18P4`, `#DSZi0001536`, `#AFM`, `#DFMd100`.

After `FS Z`, `INFO` returns maintenance tokens instead, such as `#ADFRKIT` (roller kit) and `#ADFBGLF`/`#ADFBGLB` (eight decimal fields each, probably front and back background levels). Scanning doesn't need them.

### `EXI`, page-length limits

The data block is JSON:

```json
{"NormalSpeedLength":[{"Resolution":300,"Length":3600},{"Resolution":600,"Length":1550}],
 "MaxLength":[{"Resolution":200,"Length":24000},{"Resolution":300,"Length":21500},{"Resolution":600,"Length":5300}]}
```

Lengths are in 1/100 inch. ScanSmart sets each scan's height to the normal-speed length for its resolution (see `PARA`).

### `CAPA`, capabilities

After `FS Y`, the data block (332 bytes) lists what a scan can ask for:

| Token | FF-680W value | Reading |
|---|---|---|
| `#ADF…` | `DPLX`, `PEDT`, `DFL1DFL3`, `LDF `, `EJCT`, `CRP `, `SKEW`, `OVSN` | Feeder options. `DPLX` turns on two-sided scanning (observed). `CRP ` makes the scanner return only the paper (observed). `SKEW` probably straightens pages and `DFL1` probably detects double feeds, matching ScanSmart's options. The rest are unknown |
| `#ADFRSMSLIST` | `d300d600` | |
| `#COLLIST` | `C024M008R008G008B008` | Color modes. `C024` is 24-bit color (observed). The others are probably 8-bit monochrome and single 8-bit red, green and blue channels |
| `#FMTLIST` | `JPG ` | JPEG is the only image format |
| `#JPGRANG` | `d001d100` | JPEG quality range |
| `#GMMLIST` | `UG10UG18` | Gamma choices |
| `#GMTLIST` | `RED GRN BLU MONO` | Gamma tables that can be uploaded |
| `#CMXLIST` | `UNITUM08` | Color matrix formats |
| `#RSMLIST`, `#RSSLIST` | `d050d075d100d150d200d240d300d360d400d600` | Resolutions. ScanSmart sets `#RSM` and `#RSS` to the same value, presumably one per scan direction |
| `#CRPRANG` | `i-000020d020` | Crop adjustment range |
| `#LAMLIST` | `ON  OFF ` | |

After `FS Z`, `CAPA` returns maintenance ranges instead, including the error codes the scanner can report: `#ERRLISTNONEDCM ERR PJ  OPN PE  CLR `.

### `STAT`, status

With paper in the feeder, the reply announces no data (`STATx0000000`). With the feeder empty, it announces a 12-byte data block containing `#ERRADF PE  `. `PE` is paper empty. After an error during a scan, it announces that error until it's cleared: `#ERRADF PJ  ` after a paper jam, `#ERRADF DFED` after a double feed (see "Errors during a scan"). `DFED` isn't in `CAPA`'s `#ERRLIST`. The other codes from `#ERRLIST` (`OPN`, `DCM`, `ERR`, `CLR`) haven't been observed. `OPN` didn't appear when the cover was opened during a scan; that was reported as `DFED`.

### `PARA`, parameters

Takes a parameter block of tokens. The reply block carries `#parOK  ` on success.

ScanSmart uses it twice. Before reading maintenance data it sends only `#D&Tx…`, apparently the date and time; the encoding is unknown. To start a scan it sends the scan's parameters (next section).

### `RESA`, counters and settings

Returns maintenance counters and settings, such as `#ADFSCNT` and `#ADFJAM ` counts, `#SAV` (sleep timer), `#D&T`, and `#BSZi0065536`. Scanning doesn't need it.

### `TRDT`, start transfer

No parameters. Sent after the scan's `PARA`. The scanner starts feeding paper.

### `IMG`, image data

See "Image transfer" below.

### `CAN`, cancel

No parameters. Stops a scan after `TRDT`. The reply block is `CAN x0000000` with no tokens and no data. See "Cancelling" below.

### `FIN`, finish

Ends the current mode. ScanSmart sends it after each round of queries and at the end of a scan, before unlocking.

## Scanning

### Sequence

ScanSmart's full scan, after the opening:

1. `FS Y`, then `INFO`, `EXI`, `CAPA`, `FIN`.
2. `FS Z`, then `STAT`, `INFO`, `CAPA`, `PARA` (date and time), `RESA`, `FIN`. This is maintenance and not needed to scan.
3. Several rounds of `FS Y`, `STAT`, `FIN`, in quick bursts over about half a second. They check the scanner's state before scanning: in the uncleared-jam capture every one answered `#ERRADF PJ  ` and ScanSmart never went on to step 4 (see "Errors during a scan").
4. `FS X`, then `STAT`, then `PARA` with the scan parameters, then `TRDT`.
5. `IMG` repeatedly until the feeder is empty (below).
6. `STAT` up to three times (each answering `#ERRADF PE  `, feeder empty), then `FIN`.
7. Unlock, and the connection closes.

ScanSmart sometimes runs steps 1–2 on extra connections before the scan, for example right after its settings change. Each ends with `FIN` and an unlock.

### Scan parameters

The parameter block ScanSmart sends with `PARA` for a scan. It was about 1,000 bytes, in this order:

| Token | One-sided, 300 dpi | Two-sided, 600 dpi | Reading |
|---|---|---|---|
| `#ADF` | `CRP SKEWDFL1` | `CRP SKEWDPLXDFL1` | Feeder options from `CAPA`, concatenated: crop, straighten, two-sided, double-feed detection |
| `#RSM` | `i0000300` | `i0000600` | Resolution |
| `#RSS` | `i0000300` | `i0000600` | Resolution, always equal to `#RSM` |
| `#COL` | `C024` | `C024` | 24-bit color |
| `#FMT` | `JPG ` | `JPG ` | |
| `#JPG` | `d090` | `d090` | JPEG quality 90 |
| `#GMM` | `UG18` | `UG18` | |
| `#GMTRED h100` | 256 bytes | same | Red gamma table |
| `#GMTBLU h100` | 256 bytes | same | Blue gamma table |
| `#GMTGRN h100` | 256 bytes | same | Green gamma table |
| `#CMXUM08h009` | 9 bytes, then 3 bytes `00` | same | Color matrix |
| `#CRP` | `i0000000` | `i0000000` | Crop adjustment |
| `#DFA` | `i0000000i0001550` | same | Probably the double-feed detection area |
| `#LAM` | `OFF ` | same | |
| `#PAG` | `d000` | same | Probably the page count, 0 for no limit |
| `#ACQ` | `i0000000i0000000i0002550i0010800` | `i0000000i0000000i0005100i0009300` | Scan area: left, top, width, height in pixels |
| `#BSZ` | `i1048576` | same | Probably a transfer buffer size |

The tables Epson sends are neutral:
- **Gamma tables:** each is the identity ramp `00 01 02 … FF`, with a handful of entries off by one. Red has a skipped value near `0F` and a repeated value near `D1`. Green and blue repeat a value near `34` and skip one near `8E`.
- **Color matrix:** `20 00 00 00 20 00 00 00 20`, which reads as the identity matrix with 32 (`20`) meaning 1.0.

A client can send an exact identity ramp and identity matrix. Whether the scanner also accepts a scan with no tables at all hasn't been tested.

**The scan area** is the full width at the resolution, and a height equal to `EXI`'s normal-speed length:
- **300 dpi:** 8.5 in × 300 = 2550 pixels wide, and 36.00 in × 300 = 10,800 pixels tall.
- **600 dpi:** 8.5 in × 600 = 5100 pixels wide, and 15.50 in × 600 = 9,300 pixels tall.

With `CRP ` requested, the scanner returns only the paper, not the whole area (see below).

**ScanSmart always asks for color.** Its "grayscale" output setting didn't change the request, and it has no color option before scanning. `M008` (8-bit monochrome) is listed in `CAPA` but hasn't been observed in use.

### Image transfer

After `TRDT`, the host sends `IMG x0000000` repeatedly. Each reply block announces how many image bytes are ready (often 0) and carries tokens; the host fetches the announced bytes, then sends `IMG` again.

Tokens in `IMG` replies:

| Token | Example | Meaning |
|---|---|---|
| `#typ` | `IMGA` or `IMGB` | Which side the data belongs to: `A` front, `B` back. Present while a side is open, from the reply with its `#pst` through the one with its `#pen`. Replies outside a side (before the first `#pst`, and between one side's `#pen` and the next `#pst`) are `IMG x0000000` with no tokens at all. Both cancel captures followed this in every reply |
| `#pst` | `i0002530d000i0003311` | A side is starting. Width, `d000`, height, in pixels |
| `#pen` | `i0002530i0003311` | A side has ended. Width and height in pixels |
| `#lft` | `d000` | Sent with the last side's `#pen`: no sheets left in the feeder |
| `#err` | `ADF PJ  `, `ADF DFED` | The scan stopped on an error. Lowercase, unlike `STAT`'s `#ERR`. See "Errors during a scan" |
| `#atn` | `CAN ` | The scanner asks the host for something: `CAN ` when its Stop button is pressed. See "Cancelling" |

Tokens don't come in a fixed order: `#pst` and `#pen` came before `#typ` in the same reply block.

The image bytes for a side, concatenated in order, form one JPEG file. Each side's data starts with the reply that carries `#pst`. Data chunks were up to 262,144 bytes (0x40000).

**Sheet order:** for each sheet, the front arrives completely (`#pst` … `#pen`), then the back, then the next sheet's front. A complete capture of four sheets followed this order exactly, with no interleaving. Each reply's `#typ` still says which side its data is for.

**Polling:** while the scanner is feeding or scanning, `IMG` replies often announce no data. ScanSmart sends the next `IMG` immediately, a few milliseconds apart.

**Slow links:** over a poor Wi-Fi link, single replies took seconds to arrive: an `IMG` reply block took 4.5 seconds, and one 262,144-byte data block about 16. Nothing was wrong with the scan. A client shouldn't time out a reply that's still arriving.

**Startup:** the first `#pst` came about 8 seconds after `TRDT` at 600 dpi, with every `IMG` reply empty until then. A client has to keep polling through that, rather than treating a run of empty replies as a stalled scanner.

**Cropping:** with `CRP ` requested, each side's `#pst`/`#pen` size is the paper's, not the requested area's. Letter paper at 300 dpi came back as 2530 × 3311; at 600 dpi, fronts were 5060 pixels wide and backs 5052, with heights from 6606 to 6638 across sheets of the same paper. The JPEGs are RGB and match those sizes.

**Timing:** at 300 dpi one-sided, a letter page took about 1.4 seconds from `#pst` to `#pen`. At 600 dpi two-sided, a sheet took about 8–9 seconds, about 4.5 seconds for the front and 3.5–4.5 for the back.

### Cancelling

ScanSmart's Cancel button sent the same sequence in both cancel captures, right after an `IMG` reply (and its data, if any) had come back:

1. `CAN`, answered `CAN x0000000` with no tokens and no data.
2. `STAT` twice, both answered `STATx0000000`, no error.
3. `FIN`, then unlock. The scanner replied `A1 01` and closed the connection.

Commands went one at a time, as everywhere else: `CAN` was sent between polls, not while a reply was outstanding.

**Before any data:** the first capture's `CAN` came after 758 empty `IMG` replies over about 7.5 seconds.

**During a side:** in the second capture, the first sheet's front and back had arrived complete, and the second sheet's front had started (`#pst`, then about 4.9 MB) when ScanSmart sent `CAN`. The scanner sent no `#pen` for that side, and nothing more after `CAN`'s reply. The unfinished side is lost.

**The paper runs ahead of the data.** In the first capture, one sheet had gone all the way through when Cancel was pressed, but none of its image had been sent. In the second, three sheets had gone through and a fourth was partway in, with a short pause after the second, while the host had received only the first sheet and part of the second's front. Probably the scanner holds scanned images in its own memory and pauses feeding when that fills; that's a guess from the timing. Sheets that went through but hadn't been sent are lost on cancel.

**The scanner's Stop button** ends a scan the same way, but asks the host to do it. Partway through the first sheet's front (about 1 MB had arrived), an `IMG` reply came back as `IMG x0040000#typIMGA#atnCAN `. ScanSmart fetched the 262,144 bytes it announced, then sent the same sequence as its own Cancel: `CAN`, `STAT` twice (no error), `FIN`, unlock. The button was pressed near the end of the second sheet, so here too the paper was well ahead of the data, and the side in progress and everything after it were lost. ScanSmart closed its preview without showing a message.

**A cancel leaves a sheet in the feeder.** Both times, the sheet being fed stopped partway and had to be pulled out by hand. `STAT` reported no error with that sheet stuck, so the scanner doesn't say so.

### Errors during a scan

Three kinds of error have been captured, with two codes. All arrived as `#err` in an `IMG` reply, and ScanSmart handled them the same way.

| | Double feed | Paper jam | Cover opened |
|---|---|---|---|
| Cause | The fourth sheet was folded and went in crooked | The third sheet was held back by hand as it started to feed. The scanner tried to pull it in several times before giving up | The cover was opened as the third sheet started, with one or two sheets left in the feeder |
| Before it | Three sheets complete, front and back | Two sheets complete, front and back | Two sheets complete, front and back |
| Reply | `IMG x0000265#errADF DFED#psti0005100d000i0009300#typIMGA` | `IMG x0000000#errADF PJ  #typIMGA` | `IMG x0000265#errADF DFED#psti0005100d000i0009300#typIMGA`, the same as the double feed, both times |
| Side in progress | The error reply itself starts a front: `#pst` with the full requested area (5100 × 9300), not a paper size, and 613 bytes, the start of a JPEG | A front had started 6 seconds earlier, with `#pst` (5052 × 6622) and 613 bytes and no data since. The error reply has no `#pst` | As with the double feed: the error reply starts a front with the full requested area and 613 bytes |
| ScanSmart's message | "Double feed detected. See the documentation for instructions on removing your originals. Click [Continue] to resume scanning. Click [Stop] to stop scanning and discard scanned pages." | "A paper jam has occurred. See the documentation for instructions on removing your originals. Click [Continue] to resume scanning. Click [Stop] to stop scanning and discard scanned pages." | The same double-feed message |

In both, the side in progress never got more data or a `#pen`; it isn't a page. An error reply can still announce data: in FastScan's own jam capture it was `IMG x0001300#errADF PJ  #typIMGA`, with 4,864 bytes of the side in progress. They have to be fetched like any other, to keep the connection in step, and then discarded. Every side before it was a complete JPEG of the size its `#pen` gave.

**ScanSmart's sequence**, every time: it stopped polling `IMG`, without sending `CAN`. 3.6 to 7.2 seconds later it sent `STAT` (`STATx000000C`, then a 12-byte block), then `FIN` and unlock. `STAT` gave the same code as `#err`, except after the cover was opened with one sheet left: that sheet had fallen through, and `STAT` answered `#ERRADF PE  `, the empty feeder. After the jam, Stop was clicked in ScanSmart's message; nothing more was sent on the scanner's port after the unlock. The varying wait suggests the `STAT`, `FIN` and unlock follow the click, though that isn't certain.

**Before the jam** the scanner retried for about a minute: ScanSmart's `IMG` polls got 8,260 empty replies between the second sheet's back `#pen` and the third sheet's `#pst`. A client has to keep polling through this as through the startup delay.

**Reading the codes:** `PJ` as a paper jam matches ScanSmart's message. `DFED` is broader than its name suggests: a folded, crooked sheet set it off without two sheets being fed together, and so did opening the cover, whether one sheet was left in the feeder or two. Probably it means the feeder stopped for something other than a jam; that's a guess. ScanSmart calls it a double feed either way. Opening the cover doesn't always give `DFED`: in two more runs that weren't captured, once partway through the first sheet and once as the third sheet started, ScanSmart showed its paper-jam message instead. Which code the scanner sent then wasn't captured. The scanner's `RESA` counters suggest `PJ`: across the captured sessions, `#ADFDFUS` rose by one for each `DFED`, while across the two uncaptured runs `#ADFJAM ` rose (by four) and `#ADFDFUS` didn't. That's an inference from counters whose meanings are themselves guesses.

**On the scanner**, the sheet stopped in the feeder both times. After the double feed, the scanner stayed in an error state until its cover was opened, the sheet taken out, and the cover closed again; then it was ready to scan. Until then, the error outlasts the session.

**An uncleared error carries over.** Starting a scan right after the paper jam, before opening and closing the scanner, ScanSmart opened a new connection and ran its maintenance queries and status rounds as usual. Every `STAT`, in `FS Z` and `FS Y` both, answered `#ERRADF PJ  `. ScanSmart ran eight `FS Y`, `STAT`, `FIN` rounds in under a second, never sent `FS X`, and unlocked about 14 seconds later.

### End of a scan

After the `#pen` with `#lft d000`, ScanSmart stops sending `IMG`. It sends `STAT` (answering `#ERRADF PE  `), then `FIN`, then unlocks.

## Scanning from the scanner's button

Pressing the scanner's start button makes it look for a computer to scan to, over a second protocol on port 2968. The scan itself is then an ordinary scan on port 1865, run by the computer.

### Finding a computer (SLP, UDP 2968)

The scanner multicasts three identical requests to 239.255.255.253, UDP port 2968, about 20 ms apart. They're SLP version 2 (RFC 2608) messages, on port 2968 rather than SLP's usual 427:

| Field | Bytes | Value |
|---|---|---|
| Header | `02 06 00 00 66 20 00 00 00 00 00 01 00 02 65 6E` | Version 2, function 6 (attribute request), length 102, flags `20 00` (multicast), no extension, XID 1 here (the XID counts up with each press, the same in all three requests), language `en` |
| Previous responders | `00 00` | None |
| URL | `00 1C` + 28 bytes | `service:NetScanMonitor-agent` |
| Scope | `00 08` + 8 bytes | `PID 016B` |
| Tags | `00 28` + 40 bytes | `Ver,ClientName,IPAddress,EventPort,Group` |
| SPI | `00 00` | None |

A computer running Epson's agent answers by unicast, from an ephemeral port to the scanner's port 2968, with an SLP attribute reply: the header `02 07 00 00 70 00 00 00 00 00 00 01 00 02 65 6E` (function 7, length 112, the XID of the request it answers), the error code `00 00`, `00 5B` and 91 bytes of attributes (their length depends on the computer's name and address), then `00` for no authentication blocks:

```
(Ver=3.0),(ClientName=<the Mac's name>),(IPAddress=192.168.3.195),(EventPort=2968),(Group=0)
```

The agent sent it three times, about 0.5 seconds apart. The scanner accepted the first, about 25 ms after its own request; it answered the later two with ICMP port unreachable, so it listens only briefly.

**The address matters.** `IPAddress` is where the scanner sends its HTTP requests next, and it then serves port 1865 only to that address. In the "wrong address" capture, the agent advertised the Mac's Wi-Fi address, 192.168.0.95, while ScanSmart connected over Ethernet from 192.168.3.195. Those connections got the greeting `01 04 82` and were closed at once, and nothing scanned. Anything the scanner sent to the Wi-Fi address wasn't captured. With one address, it worked.

### Push scan requests (HTTP, TCP 2968)

The scanner then connects to the advertised address and `EventPort`, and sends HTTP/1.0 requests, one per connection, each answered and closed:

```
POST /PushScan HTTP/1.0
Content-Type: application/octet-stream
Content-Length: <length>
x-protocol-name: Epson Network Service Protocol
x-protocol-version: 3.00
x-uid: <counter>
```

`x-uid` counted up across the requests: 2, 3, 4. Each body is a SOAP 1.2 envelope (`http://www.w3.org/2003/05/soap-envelope`) whose body element is in the namespace `http://schema.epson.net/EpsonNet/Scan/2004/pushscan`. Every request carries `ProductNameIn` (`PID 016B`), `IPAddressIn` (the scanner's address in hex, `C0A8007F` for 192.168.0.127) and `MACAddressIn` (the scanner's MAC address, 12 hex digits).

| Time | Request element | Other contents | ScanSmart's answer (`StatusOut`) |
|---|---|---|---|
| 1.0 s after the press | `JobList` | `CapabilityIn` twice: `OfficeFormat`, `PanelData=0110` | `OK`, with `CapabilityOut` echoing both |
| 2.1 s | `PushScan` | `JobNumberIn` `0` | `OK` |
| After the scan | `ScanEnd` | none | `ERROR` |

The answers are HTTP/1.0 `200 OK`, with `Server : Epson Net Scan Monitor/2.0`, the same `Content-Type`, protocol name, version and `x-uid` as the request, and `x-status : 0001`. ScanSmart writes these header names with a space before the colon. Each body is a `PushScanResponse` element in the same namespace. Why ScanSmart answered `ScanEnd` with `ERROR` isn't known; the scan had finished normally.

### Job sessions (port 1865)

Between answering `JobList` and `PushScan`, ScanSmart opened two short sessions on port 1865, each with the greeting, the lock (ending `00 1E`), one `23 00` request and unlock. A `23 00` request has the same data header as `20 00`.

- **`JOBW`**, 50 bytes, expecting no reply bytes: `JOBW`, 16 zero bytes, `01 1A 18 00 00 00 00 0A 00 00`, the UTF-16LE text `Dummy`, then `03 00 00 00 02 00 00 02 01 00`. The scanner replied `A3 00` with an empty payload. Probably it writes a job named "Dummy"; the fields are unknown.
- **`JOBR`**, 4 bytes, expecting 8. The scanner replied `03 00 02 00 00 02 00 01`, which resembles the end of `JOBW`'s payload. Probably it reads the job back.

### What the computer has to send

FastScan's own client answered four button presses, changing one thing at a time. Each press was a single stack, with ScanSmart quit and Epson's Event Manager, which owns port 2968, stopped:

| Press | Answer | What happened |
|---|---|---|
| 1 | `ClientName=FastScan`, one answer per request (three) | The scanner never connected back. Its blue light flashed twice |
| 2 | `ClientName=FastScan`, one answer per press | The scanner never connected back. Blue light, then the warning light, then the Wi-Fi light |
| 3 | The computer's local name cut to 15 characters, as Epson's agent sends it; one answer | `JobList` arrived and was answered `OK`. Then nothing: no `PushScan` or `ScanEnd` in the four minutes captured, with the light flashing |
| 4 | The same, then the `JOBW` and `JOBR` sessions straight after answering `JobList` | `PushScan` came 1 second later, the scan ran, and `ScanEnd` was answered `OK` |

- **The name:** the scanner accepted the computer's local name, cut to 15 characters, and refused `FastScan`. Why isn't known. It might accept only names it has seen before, or check their form. Whether several answers to one press also cause a refusal isn't known either: presses 1 and 2 both used `FastScan`.
- **The job:** the scanner waits for the `JOBW` and `JOBR` sessions before sending `PushScan`, and gives no sign of giving up. ScanSmart wrote the job before answering `JobList`; answering first and writing the job straight after worked too.
- **`ScanEnd`:** answering `OK` (ScanSmart answered `ERROR`) made no visible difference.

### The scan

After answering `PushScan`, ScanSmart scanned exactly as it does when its own Scan button is pressed: the same queries, `FS X`, a 1000-byte `PARA` with its usual parameters, `TRDT` and the `IMG` loop, ending when the feeder was empty. Nothing in the scan referred to the button or the job. About 25 ms after ScanSmart unlocked, the scanner sent `ScanEnd`.

## FastScan's needs

To scan, a client needs:
- **Opening:** the greeting, lock, and `FS Y`.
- **Optional checks:** `INFO` to confirm the product is `FF-680W`, and `EXI` for the scan height.
- **Feeder check:** `FS Y`, `STAT`, `FIN` before the scan, as ScanSmart does. `#ERRADF PE  ` means the feeder is empty; `PJ` or `DFED` means an earlier error hasn't been cleared.
- **The scan:** `FS X`, `STAT`, `PARA` with the scan parameters, `TRDT`, then the `IMG` loop.
- **Cancelling:** `CAN` between `IMG` polls, then `FIN` and unlock. `#atnCAN ` in an `IMG` reply (the scanner's Stop button) asks for the same, after fetching the data that reply announced.
- **Errors:** `#err` in an `IMG` reply stops the scan; `PJ` is a paper jam and `DFED` a double feed. Stop polling, then `FIN` and unlock. The sheets already received are complete, and the rest can be scanned in a new session once the sheet is cleared.
- **Closing:** `FIN` and unlock.
- **Optionally, the scanner's start button:** answer the SLP request on UDP 2968 with the computer's local name and the address the scan will come from, answer `JobList` on TCP 2968, write and read the job (`JOBW`, `JOBR`), answer `PushScan`, then scan as usual.

It doesn't need the maintenance queries (`FS Z`, the extended `INFO`/`CAPA`, `RESA`, the date and time), TLS, SNMP, or the UDP exchange.

## Open questions

- **Gray scans:** what `#COLM008` produces, and whether it's worth using. Epson's software never asks for it.
- **No tables:** whether the scanner accepts a scan without gamma tables and a color matrix.
- **Other errors during a scan:** what the unobserved `#ERRLIST` codes (`OPN`, `DCM`, `ERR`, `CLR`) mean, and whether `#atn` carries anything other than `CAN `.
- **Continuing after an error:** what ScanSmart sends if Continue is chosen after a jam or double feed.
- **Scanning from the button:** why the scanner refuses some computer names, what the `JOBW` and `JOBR` fields mean, what `PanelData=0110` and `Group` stand for, why ScanSmart answered `ScanEnd` with `ERROR`, and what happens when two computers answer.
- **Unknown values:** the greeting's payload, the lock payload's fields, the date-and-time encoding, and several `INFO` tokens.
