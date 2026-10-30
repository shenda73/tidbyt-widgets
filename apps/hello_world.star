"""
Hello World for Tidbyt.
Shows a greeting on two lines with a scrolling message underneath.
"""

load("render.star", "render")

def main():
    return render.Root(
        delay = 80,  # ms per animation frame
        child = render.Column(
            expanded = True,
            main_align = "space_around",
            cross_align = "center",
            children = [
                render.Text("Hello,", color = "#ffcc00", font = "6x13"),
                render.Text("World!", color = "#33ccff"),
                render.Marquee(
                    width = 64,
                    child = render.Text("made with Pixlet :)", color = "#ff66aa"),
                ),
            ],
        ),
    )
