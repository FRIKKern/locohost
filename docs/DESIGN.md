# Menu standard

WorkForest and LocoHost share one standard for their menus. A change that breaks a rule here is a bug.

## The menu is native

The menu is an NSMenu. A popover was tried and felt slow next to the system's own menus. Custom views are used only for text meant to be read: the header, the summary and the hover card. Text that should be read is never a disabled item, because macOS greys those out.

## Every line earns its place

1. Every line answers a question the person has. Nothing decorative: no SF Symbols on items, no bars that need a legend, no unlabeled icon rows.
2. A number appears once. The header counts. Section headers do not repeat counts, and rows do not repeat what their section says.
3. The main menu holds at most:
   - a header of two lines
   - a summary of at most three lines, cut at a whole sentence and never mid-word
   - two actions, shown only when they can do something
   - four sections of at most six rows each, with the rest under a "More" item
   - a footer of at most three items, such as Recently Stopped, Settings and Quit
4. A row is a name and at most three facts, ordered owner · size · state. No badge when the section already says it.
5. A hover card holds:
   - a title of one or two lines
   - a colored status of at most two lines, saying in plain words why the item stays or when it goes, and what happens next
   - at most five aligned facts, leaving out the empty ones
   - the model's note in at most two lines, and only when it adds to the status
   - at most four actions, with the rest under More

## Words

- Plain words. "Squash-merged", not "merged (squash)". "Remote branch deleted", not "upstream gone". "1 commit not in main", not "1 not in main".
- No parentheses as asides.
- Gray tails carry only time and size: "Review Now   9m ago", "Close Idle   2 servers, 1.2 GB".
- Truncate at the tail, never in the middle.

## Checked, not assumed

After any change to the menu, render the header and hover cards offscreen to PNG (compile `main.m` with `-Dmain=lh_main` into a small harness) and look at the PNGs in light and dark. Check that:

- titles and the first fact on each line are not cut off
- the fact columns line up from card to card
- spacing stays even
- nothing says the same thing twice
