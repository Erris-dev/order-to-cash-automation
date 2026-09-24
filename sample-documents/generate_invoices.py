"""Generate the fictional supplier documents used to test WF-04.

Runs inside the Odoo container, which already ships reportlab and Pillow:

    docker compose run --rm --no-deps -v ./sample-documents:/out \
        --entrypoint python3 odoo /out/generate_invoices.py

All companies, addresses and VAT IDs are made up.
"""

import io
import random
from decimal import Decimal

from PIL import Image, ImageDraw, ImageFilter, ImageFont
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

OUT = "/out"
FONT_DIR = "/usr/share/fonts/truetype/dejavu"
pdfmetrics.registerFont(TTFont("Sans", f"{FONT_DIR}/DejaVuSans.ttf"))
pdfmetrics.registerFont(TTFont("Sans-Bold", f"{FONT_DIR}/DejaVuSans-Bold.ttf"))

BUYER = ["Muster GmbH", "Einkauf", "Musterstraße 1", "20095 Hamburg"]


def eur(value, lang="de"):
    q = Decimal(value).quantize(Decimal("0.01"))
    s = f"{q:,.2f}"
    if lang == "de":
        s = s.replace(",", "X").replace(".", ",").replace("X", ".")
    return s + " €"


def totals(lines, rate):
    net = sum(Decimal(str(q)) * Decimal(str(p)) for _, q, p in lines)
    vat = (net * Decimal(rate) / 100).quantize(Decimal("0.01"))
    return net, vat, net + vat


LABELS = {
    "de": dict(title="RECHNUNG", no="Rechnungsnummer", date="Rechnungsdatum", due="Fällig am",
               pos="Pos.", desc="Bezeichnung", qty="Menge", unit="Einzelpreis", total="Gesamt",
               net="Nettobetrag", vat="zzgl. USt. {r} %", gross="Rechnungsbetrag",
               vatid="USt-IdNr.", pay="Zahlbar ohne Abzug innerhalb von 30 Tagen."),
    "en": dict(title="INVOICE", no="Invoice number", date="Invoice date", due="Due date",
               pos="#", desc="Description", qty="Qty", unit="Unit price", total="Amount",
               net="Net amount", vat="VAT {r} %", gross="Total due",
               vatid="VAT ID", pay="Payable within 30 days without deduction."),
}


def draw_invoice(c, inv, total_override=None):
    """Draw one invoice page on a reportlab canvas (A4)."""
    L = LABELS[inv["lang"]]
    w, h = A4
    c.setFont("Sans-Bold", 16)
    c.drawString(20 * mm, h - 25 * mm, inv["supplier"][0])
    c.setFont("Sans", 9)
    for i, line in enumerate(inv["supplier"][1:]):
        c.drawString(20 * mm, h - 31 * mm - i * 4.5 * mm, line)
    c.drawString(20 * mm, h - 31 * mm - len(inv["supplier"][1:]) * 4.5 * mm, f"{L['vatid']}: {inv['vat_id']}")

    c.setFont("Sans", 10)
    for i, line in enumerate(BUYER):
        c.drawString(20 * mm, h - 62 * mm - i * 5 * mm, line)

    c.setFont("Sans-Bold", 18)
    c.drawString(20 * mm, h - 95 * mm, L["title"])
    c.setFont("Sans", 10)
    meta = [(L["no"], inv["number"]), (L["date"], inv["date"]), (L["due"], inv["due"])]
    for i, (k, v) in enumerate(meta):
        c.drawString(120 * mm, h - 62 * mm - i * 5 * mm, f"{k}:")
        c.drawRightString(190 * mm, h - 62 * mm - i * 5 * mm, v)

    y = h - 110 * mm
    c.setFont("Sans-Bold", 9)
    for x, txt, right in [(20, L["pos"], False), (30, L["desc"], False), (125, L["qty"], True),
                          (155, L["unit"], True), (190, L["total"], True)]:
        (c.drawRightString if right else c.drawString)(x * mm, y, txt)
    c.line(20 * mm, y - 2 * mm, 190 * mm, y - 2 * mm)
    c.setFont("Sans", 9)
    lang = inv["lang"]
    for i, (desc, qty, price) in enumerate(inv["lines"], start=1):
        y -= 7 * mm
        line_total = Decimal(str(qty)) * Decimal(str(price))
        c.drawString(20 * mm, y, str(i))
        c.drawString(30 * mm, y, desc)
        c.drawRightString(125 * mm, y, str(qty))
        c.drawRightString(155 * mm, y, eur(price, lang))
        c.drawRightString(190 * mm, y, eur(line_total, lang))

    net, vat, gross = totals(inv["lines"], inv["rate"])
    if total_override is not None:
        gross = Decimal(total_override)
    y -= 6 * mm
    c.line(110 * mm, y, 190 * mm, y)
    for label, amount, bold in [(L["net"], net, False), (L["vat"].format(r=inv["rate"]), vat, False),
                                (L["gross"], gross, True)]:
        y -= 6 * mm
        c.setFont("Sans-Bold" if bold else "Sans", 10)
        c.drawString(110 * mm, y, label)
        c.drawRightString(190 * mm, y, eur(amount, lang))

    c.setFont("Sans", 8)
    c.drawString(20 * mm, 30 * mm, L["pay"])
    c.drawString(20 * mm, 25 * mm, inv["bank"])


def write_pdf(name, inv, total_override=None):
    c = canvas.Canvas(f"{OUT}/{name}", pagesize=A4)
    c.setTitle(f"{inv['supplier'][0]} {inv['number']}")
    draw_invoice(c, inv, total_override)
    c.showPage()
    c.save()
    print("wrote", name)


def write_blurry_scan(name, inv):
    """Render the invoice as a low-resolution image, then blur, skew and add noise."""
    # Draw the content with Pillow at fax-like resolution (~60 dpi).
    scale = 60 / 25.4 / (72 / 25.4)  # points -> pixels at 60 dpi
    W, H = int(A4[0] * scale), int(A4[1] * scale)
    img = Image.new("L", (W, H), 235)
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(f"{FONT_DIR}/DejaVuSans.ttf", 9)
    bold = ImageFont.truetype(f"{FONT_DIR}/DejaVuSans-Bold.ttf", 12)
    L = LABELS[inv["lang"]]
    lines = [(inv["supplier"][0], bold)] + [(t, font) for t in inv["supplier"][1:]]
    lines += [("", font)] + [(t, font) for t in BUYER] + [("", font), (L["title"], bold)]
    lines += [(f"{L['no']}: {inv['number']}   {L['date']}: {inv['date']}", font), ("", font)]
    for i, (desc, qty, price) in enumerate(inv["lines"], start=1):
        lt = Decimal(str(qty)) * Decimal(str(price))
        lines.append((f"{i}  {desc}   {qty} x {eur(price)} = {eur(lt)}", font))
    net, vat, gross = totals(inv["lines"], inv["rate"])
    lines += [("", font), (f"{L['net']}: {eur(net)}", font),
              (f"{L['vat'].format(r=inv['rate'])}: {eur(vat)}", font), (f"{L['gross']}: {eur(gross)}", bold)]
    y = 25
    for text, f in lines:
        d.text((28, y), text, fill=30, font=f)
        y += 15

    random.seed(4)
    img = img.rotate(2.2, resample=Image.BICUBIC, expand=False, fillcolor=210)
    img = img.filter(ImageFilter.GaussianBlur(1.0))
    px = img.load()
    for _ in range(W * H // 20):
        x, yy = random.randrange(W), random.randrange(H)
        px[x, yy] = random.choice([60, 120, 255])
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    jpg = io.BytesIO()
    img.save(jpg, "JPEG", quality=22)
    jpg.seek(0)

    c = canvas.Canvas(f"{OUT}/{name}", pagesize=A4)
    c.drawImage(ImageReader(jpg), 0, 0, width=A4[0], height=A4[1])
    c.showPage()
    c.save()
    print("wrote", name)


def write_delivery_note(name):
    c = canvas.Canvas(f"{OUT}/{name}", pagesize=A4)
    w, h = A4
    c.setFont("Sans-Bold", 16)
    c.drawString(20 * mm, h - 25 * mm, "Hanseatische Papierwaren GmbH")
    c.setFont("Sans-Bold", 18)
    c.drawString(20 * mm, h - 60 * mm, "LIEFERSCHEIN Nr. LS-2026-55120")
    c.setFont("Sans", 10)
    rows = ["Lieferung an: Muster GmbH, Musterstraße 1, 20095 Hamburg",
            "Lieferdatum: 21.09.2026   Bestellung: PO-4471",
            "", "12 Karton  Servietten 3-lagig weiß 40x40 (1.000 Stk)",
            "8 Karton   Coffee-to-go Becher 300 ml (1.000 Stk)",
            "8 Karton   Deckel schwarz 300 ml (1.000 Stk)",
            "", "Ware vollständig und unbeschädigt erhalten:  ____________________",
            "", "Dies ist keine Rechnung. Die Rechnung folgt separat."]
    for i, r in enumerate(rows):
        c.drawString(20 * mm, h - 75 * mm - i * 6 * mm, r)
    c.showPage()
    c.save()
    print("wrote", name)


PAPER = dict(
    lang="de", rate=19, number="HP-2026-10417", date="22.09.2026", due="22.10.2026",
    vat_id="DE287654321",
    supplier=["Hanseatische Papierwaren GmbH", "Speicherstadt 12", "20457 Hamburg"],
    bank="Hamburger Sparkasse · IBAN DE00 2005 0550 0000 1234 56 · BIC HASPDEHHXXX",
    lines=[("Servietten 3-lagig weiß 40x40, Karton 1.000 Stk", 12, "38.50"),
           ("Coffee-to-go Becher 300 ml, Karton 1.000 Stk", 8, "64.90"),
           ("Deckel schwarz 300 ml, Karton 1.000 Stk", 8, "32.35")],
)
PAPER_REORDER = dict(
    PAPER, number="HP-2026-10588", date="29.09.2026", due="29.10.2026",
    lines=[("Servietten 3-lagig weiß 40x40, Karton 1.000 Stk", 6, "38.50"),
           ("Rührstäbchen Holz 14 cm, Karton 10.000 Stk", 4, "27.80")],
)
COFFEE = dict(
    lang="en", rate=7, number="NL-88213", date="24.09.2026", due="24.10.2026",
    vat_id="DE312345678",
    supplier=["Nordlicht Kaffeerösterei KG", "Am Sandtorkai 40", "20457 Hamburg"],
    bank="Commerzbank · IBAN DE00 2004 0000 0012 3456 78 · BIC COBADEFFXXX",
    lines=[("Espresso blend 'Hafenkante', 1 kg", 40, "18.90"),
           ("Filter coffee 'Elbe', 1 kg", 8, "13.00")],
)
CLEANING = dict(
    lang="de", rate=19, number="2026-0931", date="25.09.2026", due="09.10.2026",
    vat_id="DE298765432",
    supplier=["CleanPro Hygiene GmbH", "Industriestraße 5", "22525 Hamburg"],
    bank="Deutsche Bank · IBAN DE00 2007 0000 0098 7654 32 · BIC DEUTDEHHXXX",
    lines=[("Allzweckreiniger 10 l Kanister", 20, "24.50"),
           ("Spülmaschinentabs, Eimer 200 Stk", 15, "58.00"),
           ("Handseife mild 5 l", 32, "20.00")],
)
TEXTILE = dict(
    lang="de", rate=19, number="W-1187", date="26.09.2026", due="26.10.2026",
    vat_id="DE276543219",
    supplier=["Gastro-Textil Weber e.K.", "Lindenallee 8", "21073 Hamburg"],
    bank="Haspa · IBAN DE00 2005 0550 0000 7654 32",
    lines=[("Tischdecke 130x170 weiß", 24, "21.50"),
           ("Geschirrtuch Halbleinen", 60, "3.90")],
)

if __name__ == "__main__":
    write_pdf("01-invoice-ok-paper-19pct.pdf", PAPER)
    write_pdf("02-invoice-ok-coffee-7pct-en.pdf", COFFEE)
    # lines: 490 + 870 + 640 = 2,000.00 net, 380.00 VAT -> correct total is 2,380.00
    write_pdf("03-invoice-wrong-total.pdf", CLEANING, total_override="2480.00")
    write_blurry_scan("04-invoice-blurry-scan.pdf", TEXTILE)
    write_delivery_note("05-delivery-note-not-an-invoice.pdf")
    # second, clean invoice from a known vendor: vendor is matched by VAT ID, not created again
    write_pdf("06-invoice-ok-paper-reorder.pdf", PAPER_REORDER)
