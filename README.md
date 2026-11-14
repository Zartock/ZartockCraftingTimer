# Zartock Crafting Timer

Shows how long it takes until your whole crafting queue is finished.

The cast bar only tells you about the item being made right now. When you
press "Create All" or queue up 40 potions, this addon adds a small timer that
counts down to the end of the entire queue, along with how many crafts are
left, so you know whether you have time to grab a coffee.

## Features

- A countdown for the whole queue, not just the current craft.
- Shows the number of crafts left.
- Accounts for the short pause the game adds between crafts, so the timer
  runs evenly instead of drifting or jumping.
- Appears only while you are crafting more than one item, and hides itself
  when the queue finishes or is interrupted.
- Works with every profession, with no setup.
- Movable: drag it wherever you like, and it remembers the position.

## Commands

| Command      | What it does                                                         |
| ------------ | -------------------------------------------------------------------- |
| `/zct`       | Shows the timer with sample numbers so you can drag it into place. Type it again to hide it. |
| `/zct reset` | Puts the timer back in its default position.                         |
| `/zct log`   | Turns recording of craft timings on or off, for troubleshooting.     |

## Good to know

The game does not tell addons how long the pause between two crafts is, so the
addon measures it as you craft and remembers it. During your very first queue
the timer may be slightly off while it learns; after that it starts out
accurate.

## Feedback

Found a bug or have a suggestion? Please open an issue on the project's
GitHub page.
