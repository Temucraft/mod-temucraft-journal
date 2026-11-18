-- mod-temucraft-journal: player-facing texts. Translations go in module_string_locale (same module and id, plus the locale).
DELETE FROM `module_string` WHERE `module` = 'mod-temucraft-journal';
INSERT INTO `module_string` (`module`, `id`, `string`) VALUES
('mod-temucraft-journal', 1, 'Could not write {}.'),
('mod-temucraft-journal', 2, 'Journal: {} instances, {} bosses, {} loot entries written to {}. Copy it into Interface\\AddOns\\TemucraftJournal\\ and /reload.');
