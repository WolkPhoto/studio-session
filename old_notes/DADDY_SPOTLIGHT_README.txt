DADDY SPOTLIGHT EASTER EGG

1. Build Digi Suite with BUILD_THIS_VERSION.command.
2. Run INSTALL_DADDY_SPOTLIGHT.command from the same extracted folder.
3. Search Spotlight for Daddy.

This creates a Finder alias called Daddy in ~/Applications, pointing to the built Digi Suite.app. It does not rename or duplicate Digi Suite. The alias is visible to anyone browsing ~/Applications. Spotlight indexing is controlled by macOS and is not guaranteed to be immediate. If you later move the built app, rerun the installer from its new build folder.

Important: If you distribute the app to customers, this installer must be run on their Macs (or included as an explicit step in a signed installer). Simply distributing the app bundle will not create the alias.
