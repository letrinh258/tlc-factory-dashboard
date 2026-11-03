const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  Table, TableRow, TableCell, WidthType, ShadingType, BorderStyle,
  LevelFormat, convertInchesToTwip
} = require("docx");

const FONT = "Arial";
const md = fs.readFileSync("HUONGDAN_DRAFT.md", "utf8");
const lines = md.split("\n");

// ---------- inline formatting: **bold** and `code` ----------
function inlineRuns(text, baseOpts) {
  baseOpts = baseOpts || {};
  // Thứ tự alternation quan trọng: **bold** phải thử trước *italic* để không
  // bị regex đơn-sao nuốt nhầm 2 dấu sao liền nhau.
  const parts = text.split(/(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*)/g).filter(s => s.length);
  return parts.map(p => {
    if (p.startsWith("**") && p.endsWith("**")) {
      return new TextRun({ text: p.slice(2, -2), bold: true, font: FONT, ...baseOpts });
    }
    if (p.startsWith("`") && p.endsWith("`")) {
      // Dùng Arial thay vì font monospace: Consolas/Courier thiếu glyph dấu
      // tiếng Việt tổ hợp (vd "số", "tự") trên môi trường render Linux,
      // gây vỡ chữ. Chỉ đổi màu để vẫn phân biệt được là "code".
      return new TextRun({ text: p.slice(1, -1), font: FONT, color: "AD1457", ...baseOpts });
    }
    if (p.startsWith("*") && p.endsWith("*")) {
      return new TextRun({ text: p.slice(1, -1), italics: true, font: FONT, ...baseOpts });
    }
    return new TextRun({ text: p, font: FONT, ...baseOpts });
  });
}

function para(text, opts) {
  opts = opts || {};
  return new Paragraph({
    children: inlineRuns(text, opts.runOpts),
    spacing: { after: 120 },
    ...opts.paraOpts
  });
}

function bullet(text) {
  return new Paragraph({
    children: inlineRuns(text),
    numbering: { reference: "guide-bullets", level: 0 },
    spacing: { after: 80 }
  });
}

function quote(text) {
  return new Paragraph({
    children: inlineRuns(text, { italics: true, color: "555555" }),
    spacing: { after: 160 },
    border: { left: { style: BorderStyle.SINGLE, size: 12, color: "9E9E9E", space: 8 } },
    indent: { left: 200 }
  });
}

// ---------- table parsing ----------
function parseTableBlock(rows) {
  // rows: array of raw "| a | b |" lines, rows[1] is the --- separator
  const cells = rows.map(r => r.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map(c => c.trim()));
  const header = cells[0];
  const body = cells.slice(2); // skip separator row
  const colWidths = header.map(() => Math.floor(9000 / header.length));
  const mkRow = (cols, isHeader) => new TableRow({
    tableHeader: isHeader,
    children: cols.map((c, i) => new TableCell({
      width: { size: colWidths[i], type: WidthType.DXA },
      shading: isHeader ? { type: ShadingType.CLEAR, fill: "1F4E78" } : undefined,
      margins: { top: 80, bottom: 80, left: 100, right: 100 },
      children: [new Paragraph({
        children: inlineRuns(c, isHeader ? { bold: true, color: "FFFFFF" } : {})
      })]
    }))
  });
  return new Table({
    width: { size: 9000, type: WidthType.DXA },
    columnWidths: colWidths,
    rows: [mkRow(header, true), ...body.map(r => mkRow(r, false))]
  });
}

// ---------- main parse loop ----------
const children = [];
let i = 0;
let firstH1 = true;
while (i < lines.length) {
  const line = lines[i];
  if (line.startsWith("# ")) {
    const text = line.slice(2).trim();
    if (firstH1) {
      children.push(new Paragraph({ text, heading: HeadingLevel.TITLE, alignment: AlignmentType.CENTER }));
      children.push(new Paragraph({
        children: [new TextRun({ text: "Tài liệu nội bộ — cập nhật 03/11/2026", italics: true, color: "666666", font: FONT })],
        alignment: AlignmentType.CENTER, spacing: { after: 400 }
      }));
      firstH1 = false;
    } else {
      children.push(new Paragraph({ text, heading: HeadingLevel.HEADING_1, pageBreakBefore: true }));
    }
    i++; continue;
  }
  if (line.startsWith("## ")) {
    children.push(new Paragraph({ text: line.slice(3).trim(), heading: HeadingLevel.HEADING_2 }));
    i++; continue;
  }
  if (line.startsWith("### ")) {
    children.push(new Paragraph({ text: line.slice(4).trim(), heading: HeadingLevel.HEADING_3 }));
    i++; continue;
  }
  if (line.startsWith("> ")) {
    children.push(quote(line.slice(2).trim()));
    i++; continue;
  }
  if (line.trim().startsWith("|")) {
    const block = [];
    while (i < lines.length && lines[i].trim().startsWith("|")) { block.push(lines[i]); i++; }
    children.push(parseTableBlock(block));
    children.push(new Paragraph({ text: "", spacing: { after: 200 } }));
    continue;
  }
  if (line.trim() === "---") { i++; continue; }
  if (line.trim().startsWith("- ")) {
    children.push(bullet(line.trim().slice(2)));
    i++; continue;
  }
  if (line.trim() === "") { i++; continue; }
  children.push(para(line.trim()));
  i++;
}

const doc = new Document({
  styles: {
    default: {
      document: { run: { font: FONT, size: 22 } }
    },
    paragraphStyles: [
      {
        id: "Title", name: "Title", basedOn: "Normal", next: "Normal",
        run: { font: FONT, size: 44, bold: true, color: "1F4E78" },
        paragraph: { spacing: { after: 120 } }
      },
      {
        id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { font: FONT, size: 32, bold: true, color: "1F4E78" },
        paragraph: { spacing: { before: 0, after: 240 }, keepNext: true, border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: "1F4E78", space: 4 } } }
      },
      {
        id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { font: FONT, size: 27, bold: true, color: "2E75B6" },
        paragraph: { spacing: { before: 320, after: 140 }, keepNext: true }
      },
      {
        id: "Heading3", name: "Heading 3", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { font: FONT, size: 23, bold: true, color: "548235" },
        paragraph: { spacing: { before: 200, after: 100 }, keepNext: true }
      }
    ]
  },
  numbering: {
    config: [{
      reference: "guide-bullets",
      levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: convertInchesToTwip(0.35), hanging: convertInchesToTwip(0.2) } } } }]
    }]
  },
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 }, // US-ish default kept but content is A4 fine too; use A4 standard for VN
        margin: { top: 1000, bottom: 1000, left: 1100, right: 1100 }
      }
    },
    children
  }]
});

Packer.toBuffer(doc).then(buf => {
  fs.writeFileSync("Huong_dan_su_dung_TLC_Dashboard.docx", buf);
  console.log("DONE", buf.length, "bytes");
});
