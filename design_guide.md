# HTML-First Tools Design Guide

This guide outlines the standards and best practices for creating tools in this repository.

## Philosophy
*   **HTML-First**: The structure of the page should be built with semantic HTML.
*   **Vanilla Stack**: Use plain HTML and modern Javascript.
*   **Zero Dependencies**: Avoid external libraries (like React/Vue) unless absolutely necessary.
*   **Single File (Preferred)**: Tools should be self-contained in a single `.html` file for easy portability.

## Technology Stack
*   **HTML**: Semantic HTML5 tags.
*   **CSS**: **TailwindCSS (via CDN)**.
    *   Include: `<script src="https://cdn.tailwindcss.com"></script>`
    *   Configure the "Obsidian" theme using the `tailwind.config` script block.
*   **Icons**: **FontAwesome 6.4.0** (via CDN).
    *   Include: `<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">`
*   **Fonts**: **Inter** (UI) and **Fira Code** (Monospace).
    *   `https://fonts.googleapis.com/css2?family=Fira+Code:wght@300;400;500&family=Inter:wght@300;400;500;600&display=swap`
*   **Javascript**: Modern ES6+ syntax. No build step.

## Aesthetics & User Experience (The "Obsidian" Theme)
All tools must use the standardized "Obsidian" dark theme.

### Color Palette
Define these in your `tailwind.config`:
*   **Background (`obsidian-bg`)**: `#1e1e1e`
*   **Pane/Header (`obsidian-pane`)**: `#252526`
*   **Border (`obsidian-border`)**: `#3c3c3c`
*   **Accent (`obsidian-accent`)**: `#7c3aed` (Violet)
*   **Text (`obsidian-text`)**: `#cccccc`
*   **Muted Text (`obsidian-textMuted`)**: `#9ca3af`
*   **Success**: `#10b981`
*   **Warning**: `#f59e0b`
*   **Danger**: `#ef4444`

### Layout Standard
*   **Root**: `h-screen overflow-hidden flex flex-col`
*   **Header**: `h-14 shrink-0 border-b border-obsidian-border bg-obsidian-pane`
*   **Main**: `flex-1 overflow-auto p-4`
*   **Footer**: `shrink-0 border-t border-obsidian-border py-3`

## Standard Boilerplate
Use this structure for every new tool:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Tool Name | Homelab Playground</title>
    <link rel="icon" type="image/png" href="favicon.png">
    
    <!-- Libraries -->
    <script src="https://cdn.tailwindcss.com"></script>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@300;400;500&family=Inter:wght@300;400;500;600&display=swap" rel="stylesheet">

    <!-- Configuration -->
    <script>
        tailwind.config = {
            darkMode: 'class',
            theme: {
                extend: {
                    colors: {
                        obsidian: {
                            bg: '#1e1e1e',
                            pane: '#252526',
                            border: '#3c3c3c',
                            accent: '#7c3aed',
                            accentHover: '#6d28d9',
                            text: '#cccccc',
                            textMuted: '#9ca3af',
                        }
                    },
                    fontFamily: {
                        mono: ['"Fira Code"', 'monospace'],
                        sans: ['Inter', 'sans-serif']
                    }
                }
            }
        }
    </script>
    
    <style>
        /* Custom Scrollbar */
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: #1e1e1e; }
        ::-webkit-scrollbar-thumb { background: #3c3c3c; border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: #505050; }
    </style>
</head>
<body class="flex flex-col h-screen overflow-hidden bg-obsidian-bg text-obsidian-text font-sans">

    <!-- Header -->
    <header class="h-14 bg-obsidian-pane border-b border-obsidian-border flex items-center justify-between px-6 shrink-0 z-20">
        <div class="flex items-center gap-3">
            <i class="fa-solid fa-toolbox text-obsidian-accent text-lg"></i>
            <h1 class="font-semibold text-white tracking-tight">Tool Name</h1>
        </div>
    </header>

    <!-- Main Content -->
    <main class="flex-1 overflow-auto p-4 md:p-8 flex flex-col gap-6 max-w-6xl mx-auto w-full">
        <!-- Tool Content Here -->
    </main>

    <!-- Footer -->
    <footer class="bg-obsidian-pane border-t border-obsidian-border py-3 text-center shrink-0">
        <a href="https://homelabplayground.com" class="text-gray-500 hover:text-violet-400 text-xs transition-colors no-underline">
            HomeLab Playground
        </a>
    </footer>

    <script>
        // Tool Logic Here
    </script>
</body>
</html>
```

## SEO & Metadata
*   **Title**: `Tool Name` | Homelab Playground
*   **Favicon**: Always include `<link rel="icon" type="image/png" href="favicon.png">`
