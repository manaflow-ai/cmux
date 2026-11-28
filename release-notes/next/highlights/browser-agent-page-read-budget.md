title: Agent page reads stay fast on huge or hostile pages
category: improved

Agent snapshots, locator reads, page.content, page.markdown, searchText, extract, storageState and tabs.content now read within one page budget (250,000 nodes, 2,000,000 characters, 8 seconds). Names that share a huge label, very long link URLs, large tables, generated text and big field values no longer stall a snapshot. A read that stops early ends with "…" and says where it stopped. The viewport snapshot says "at least" when it could not count every element off screen.
