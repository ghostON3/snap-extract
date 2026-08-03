# vhs tape — terminal demo of folder mode.
# Render with: vhs contrib/demo/cli.tape   (see contrib/demo/README.md)
Output assets/cli.gif

Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set Padding 20
Set TypingSpeed 40ms

Hide
Type "cd /tmp/snapx-demo && export PATH=/tmp/snapx-demo/bin:$PATH && clear"
Enter
Sleep 1s
Show

Type "# packages/ holds only subdirectories, so a flat read finds nothing"
Enter
Sleep 800ms
Type "snap-extract.sh --folder demo-repo/packages --ext .ts --output stdout"
Enter
Sleep 2500ms

Type "clear"
Enter
Sleep 300ms

Type "# -r walks the tree. node_modules is pruned automatically."
Enter
Sleep 800ms
Type "snap-extract.sh --folder demo-repo/packages -r --ext .ts --output stdout"
Enter
Sleep 4s
