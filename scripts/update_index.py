#!/usr/bin/env python3
"""
Update index.html by inserting a new tool card at the <!-- INDEX_CARDS --> marker.
Usage: python3 update_index.py --name \"Tool Name\" --file \"tool.html\" --desc \"Description\" [--icon \"fa-solid fa-list-check\"]
"""

import argparse
import re
import sys
import os

MARKER = "<!-- INDEX_CARDS -->"
INDEX_FILE = "../index.html"  # relative to script location

def generate_card(name, file, desc, icon="fa-solid fa-list-check"):
    """Generate HTML card for the tool."""
    # Escape quotes in description
    desc = desc.replace('"', '&quot;')
    # Generate card HTML (Obsidian Pane style)
    card = f'''\t\t\t\t<a href="{file}" class="block group">
\t\t\t\t\t<div class="bg-obsidian-pane border border-obsidian-border rounded-xl p-6 h-full transition-all duration-300 card-hover group-hover:border-obsidian-accent/50">
\t\t\t\t\t\t<div class="flex items-start justify-between mb-4">
\t\t\t\t\t\t\t<div class="p-3 bg-[#111827] rounded-lg text-obsidian-accent group-hover:bg-obsidian-accent group-hover:text-white transition-colors">
\t\t\t\t\t\t\t\t<i class="{icon} text-xl"></i>
\t\t\t\t\t\t\t</div>
\t\t\t\t\t\t\t<i class="fa-solid fa-arrow-right text-gray-600 group-hover:text-obsidian-accent -translate-x-2 opacity-0 group-hover:translate-x-0 group-hover:opacity-100 transition-all"></i>
\t\t\t\t\t\t</div>
\t\t\t\t\t\t<h3 class="text-xl font-semibold text-white mb-2">{name}</h3>
\t\t\t\t\t\t<p class="text-sm text-gray-500 leading-relaxed">
\t\t\t\t\t\t\t{desc}
\t\t\t\t\t\t</p>
\t\t\t\t\t</div>
\t\t\t\t</a>
'''
    return card

def insert_card(index_path, card_html):
    """Insert card before the marker in index.html."""
    with open(index_path, 'r') as f:
        content = f.read()
    
    if MARKER not in content:
        print(f"ERROR: Marker '{MARKER}' not found in {index_path}")
        sys.exit(1)
    
    # Insert card before the marker (so new cards appear above previous ones)
    new_content = content.replace(MARKER, card_html + MARKER)
    
    with open(index_path, 'w') as f:
        f.write(new_content)
    
    print(f"Successfully inserted card for {index_path}")

def main():
    parser = argparse.ArgumentParser(description="Insert a tool card into index.html")
    parser.add_argument("--name", required=True, help="Tool name")
    parser.add_argument("--file", required=True, help="HTML file name (e.g., tool.html)")
    parser.add_argument("--desc", required=True, help="Tool description")
    parser.add_argument("--icon", default="fa-solid fa-list-check", help="Font Awesome icon class")
    
    args = parser.parse_args()
    
    # Determine absolute path to index.html (script is in scripts/ subdirectory)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    index_path = os.path.join(script_dir, INDEX_FILE)
    
    card_html = generate_card(args.name, args.file, args.desc, args.icon)
    insert_card(index_path, card_html)

if __name__ == "__main__":
    main()