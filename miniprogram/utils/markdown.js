
function escapeHtml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function parseInline(text) {
  text = text.replace(/\*\*(.+?)\*\*|__(.+?)__/g, function(_, a, b) {
    return "<strong>" + (a || b) + "</strong>";
  });
  text = text.replace(/\*(.+?)\*|_(.+?)_/g, function(_, a, b) {
    return "<em>" + (a || b) + "</em>";
  });
  text = text.replace(/`(.+?)`/g, "<code>$1</code>");
  text = text.replace(/~~(.+?)~~/g, "<del>$1</del>");
  return text;
}

function markdownToHtml(md) {
  if (!md || typeof md !== "string") return "";
  var lines = md.split("\n");
  var out = [];
  var i = 0;
  var inCodeBlock = false;

  while (i < lines.length) {
    var line = lines[i];

    // Code blocks ``` ... ```
    if (line.trim().startsWith("```")) {
      if (!inCodeBlock) {
        out.push('<pre><code>');
        inCodeBlock = true;
      } else {
        out.push("</code></pre>");
        inCodeBlock = false;
      }
      i++;
      continue;
    }
    if (inCodeBlock) {
      out.push(escapeHtml(line) + "\n");
      i++;
      continue;
    }

    // Headers
    var hMatch = line.match(/^(#{1,6})\s+(.+)/);
    if (hMatch) {
      var level = hMatch[1].length;
      out.push("<h" + level + ">" + parseInline(hMatch[2]) + "</h" + level + ">");
      i++;
      continue;
    }

    // Blockquote
    if (line.trim().startsWith("> ")) {
      var bqLines = [];
      while (i < lines.length && lines[i].trim().startsWith("> ")) {
        bqLines.push(lines[i].trim().slice(2));
        i++;
      }
      out.push("<blockquote><p>" + parseInline(bqLines.join("<br/>")) + "</p></blockquote>");
      continue;
    }

    // Unordered list
    var ulMatch = line.match(/^[\-\*\+]\s+(.+)/);
    if (ulMatch) {
      var ulItems = [];
      while (i < lines.length) {
        var m = lines[i].match(/^[\-\*\+]\s+(.+)/);
        if (!m) break;
        ulItems.push("<li>" + parseInline(m[1]) + "</li>");
        i++;
      }
      out.push("<ul>" + ulItems.join("") + "</ul>");
      continue;
    }

    // Ordered list
    var olMatch = line.match(/^\d+\.\s+(.+)/);
    if (olMatch) {
      var olItems = [];
      while (i < lines.length) {
        var m = lines[i].match(/^\d+\.\s+(.+)/);
        if (!m) break;
        olItems.push("<li>" + parseInline(m[1]) + "</li>");
        i++;
      }
      out.push("<ol>" + olItems.join("") + "</ol>");
      continue;
    }

    // Horizontal rule
    if (/^(\-{3,}|\*{3,})$/.test(line.trim())) {
      out.push("<hr/>");
      i++;
      continue;
    }

    // Empty line
    if (line.trim() === "") { i++; continue; }

    // Paragraph
    out.push("<p>" + parseInline(line) + "</p>");
    i++;
  }

  if (inCodeBlock) out.push("</code></pre>");
  return out.join("");
}

module.exports = { markdownToHtml: markdownToHtml };
