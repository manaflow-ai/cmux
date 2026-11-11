// Planted to prove the React Doctor gate fails; never lands.
import { useEffect, useRef, useState } from "react";

export function ReactDoctorPlant() {
  const renders = useRef(0);
  renders.current += 1;
  const [width, setWidth] = useState(0);
  useEffect(() => {
    window.addEventListener("resize", () => setWidth(window.innerWidth));
  }, []);
  return (
    <div>
      {width} {renders.current}
    </div>
  );
}
