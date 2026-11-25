// Scratch customization for the fresh-agent kit test (not product code): a "pinned commands" panel
// built only from Instrument (kit/index.ts). No raw colours, radii, spacing or font sizes.
import { Fragment, type ReactNode } from "react";
import {
  Button,
  Icon,
  List,
  Menu,
  MenuButton,
  MenuItem,
  MenuPopup,
  MenuSeparator,
  Panel,
  Row,
  Tooltip,
  TooltipProvider,
} from "../kit";

export interface PinnedCommandAction {
  id: string;
  label: ReactNode;
  shortcut?: string;
  onSelect(): void;
}

export interface PinnedCommand {
  id: string;
  title: ReactNode;
  subtitle?: ReactNode;
  /** A name from cmux's icon pack. */
  icon: string;
  runLabel: ReactNode;
  runTooltip: ReactNode;
  runTooltipDetail?: ReactNode;
  shortcut?: string;
  onRun(): void;
  /** Extra actions in a menu after the run button. */
  moreLabel?: string;
  moreWord?: ReactNode;
  moreActions?: PinnedCommandAction[];
}

export interface PinnedCommandsProps {
  title: ReactNode;
  empty?: ReactNode;
  commands: PinnedCommand[];
}

export function PinnedCommands({ title, empty, commands }: PinnedCommandsProps) {
  return (
    <TooltipProvider>
      <Panel role="card">
        <Panel.Header icon={<Icon name="terminal" />}>{title}</Panel.Header>
        <Panel.Body>
          <List empty={empty}>
            {commands.map((command) => (
              <Row
                key={command.id}
                title={command.title}
                subtitle={command.subtitle}
                leading={<Icon name={command.icon} row />}
                trailing={<PinnedCommandTrailing command={command} />}
              />
            ))}
          </List>
        </Panel.Body>
      </Panel>
    </TooltipProvider>
  );
}

function PinnedCommandTrailing({ command }: { command: PinnedCommand }) {
  const run = (
    <Tooltip label={command.runTooltip} detail={command.runTooltipDetail} shortcut={command.shortcut}>
      <Button size="sm" variant="subtle" onClick={command.onRun}>
        {command.runLabel}
      </Button>
    </Tooltip>
  );
  if (!command.moreActions?.length) return run;
  return (
    <>
      {run}
      <Menu>
        <MenuButton label={command.moreLabel}>{command.moreWord}</MenuButton>
        <MenuPopup label={command.moreLabel}>
          {command.moreActions.map((action, index) => (
            <Fragment key={action.id}>
              {index > 0 && <MenuSeparator />}
              <MenuItem shortcut={action.shortcut} onSelect={action.onSelect}>
                {action.label}
              </MenuItem>
            </Fragment>
          ))}
        </MenuPopup>
      </Menu>
    </>
  );
}

/** The three-row example: what a customization page would mount. */
export function PinnedCommandsExample() {
  const noop = () => {};
  return (
    <PinnedCommands
      title="Pinned commands"
      empty="Nothing pinned"
      commands={[
        {
          id: "build",
          title: "Build",
          subtitle: "bun run build",
          icon: "terminal",
          runLabel: "Run",
          runTooltip: "Run build",
          shortcut: "⌘B",
          onRun: noop,
        },
        {
          id: "test",
          title: "Test",
          subtitle: "bun test",
          icon: "terminal",
          runLabel: "Run",
          runTooltip: "Run tests",
          runTooltipDetail: "All suites in this folder",
          onRun: noop,
          moreLabel: "More test actions",
          moreWord: "More",
          moreActions: [
            { id: "watch", label: "Run in watch mode", onSelect: noop },
            { id: "unpin", label: "Unpin", onSelect: noop },
          ],
        },
        {
          id: "lint",
          title: "Lint",
          subtitle: "bun run lint",
          icon: "terminal",
          runLabel: "Run",
          runTooltip: "Run lint",
          onRun: noop,
        },
      ]}
    />
  );
}
