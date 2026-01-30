import { parse } from 'url';
import { basename, dirname } from 'path';

export function getPageName(url: string, pathPrefix = '') {
  let pathName = (parse(url).pathname || '/').slice(pathPrefix.length);
  const isPageData = pathName.startsWith('/page-data/');
  if (isPageData) {
    // "/page-data/index/page-data.json" -> "/"
    // "/page-data/using-ssr/page-data.json" -> "using-ssr"
    // "/page-data/foo/bar/ssr/page-data.json" -> "foo/bar/ssr"
    pathName = pathName.split('/').slice(2, -1).join('/');
    if (pathName === 'index') {
      pathName = '/';
    }
  } else {
    // "/using-ssr" -> "using-ssr"
    // "/using-ssr/" -> "using-ssr"
    // "/using-ssr/index.html" -> "using-ssr"
    // "/foo/bar/ssr" -> "foo/bar/ssr"
    if (basename(pathName) === 'index.html') {
      pathName = dirname(pathName);
    }
    if (pathName !== '/') {
      // Remove leading and trailing "/"
      pathName = pathName.replace(/(^\/|\/$)/g, '');
    }
  }
  return { isPageData, pathName };
}
