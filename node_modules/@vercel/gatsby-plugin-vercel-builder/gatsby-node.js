const { generateVercelBuildOutputAPI3Output } = require('./dist/index.js');

exports.onPostBuild = async ({ store }) => {
  await generateVercelBuildOutputAPI3Output({
    // validated by `pluginOptionSchema`
    gatsbyStoreState: store.getState(),
  });
};
