# samples/

Made-up UiPath workflows for trying and testing the converter. Written by hand for this project; not copied from UiPath templates or real projects. The automated tests in `tests/` depend on them, so update the tests if you change them.

| Folder | What it is | What it exercises |
| --- | --- | --- |
| `state-machine/` | A small project (`project.json`, `Main.xaml`, a `Framework\` folder): a robot that gets and handles orders, with four states, seven transitions, a final state, and the six workflows it invokes | State machines; transitions written inline and by `x:Reference`; conditions as an attribute and as an element; Studio's newer layout format (`ViewStateManager`); links from states to the workflows they invoke. Used for the main screenshot in the README |
| `flowchart/` | Sorts requests with a decision and a switch | Flowcharts; True/False and case branches; Studio's older layout format (layout on each element); a made-up activity type (`demo:RouteToQueue`); an invoked file that doesn't exist |
| `project/` | A small project (`project.json`, `Main.xaml`, a `Framework\` folder) whose workflows invoke each other | The project map; a flowchart with no saved layout; custom decision labels; a path written with `/`; a missing file; a file name worked out at run time; a made-up activity type (`acme:WarmUpCache`) |

Still to add: a sequence with an If and a Try/Catch, for when sequences are drawn.
