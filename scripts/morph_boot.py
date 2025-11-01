from morphcloud.api import MorphCloudClient


SNAPSHOT_ID = "snapshot_z8yna3wa"


def main() -> None:
    client = MorphCloudClient()

    print("booting instance...")
    instance = client.instances.start(
        snapshot_id=SNAPSHOT_ID,
        ttl_seconds=60 * 30,
        ttl_action="pause",
    )
    print(f"Created instance: {instance.id}")

    print("waiting for instance to be ready...")
    instance.wait_until_ready()
    print("instance is ready")
    print(instance.networking.http_services)

    print("executing pwd via instance.exec()...")
    print(instance.exec("pwd"))

    print("\ndone!")

    # press enter to kill
    input("Press Enter to kill instance...")
    instance.stop()
    print("instance killed")


if __name__ == "__main__":
    main()
