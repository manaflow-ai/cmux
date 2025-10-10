import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';

const projectRoot = path.resolve(__dirname, '..');

interface SecurityIssue {
  type: 'env_file' | 'secret' | 'sensitive_path';
  file: string;
  line?: number;
  content?: string;
  pattern?: string;
}

interface NpmPackFileInfo {
  path: string;
}

interface NpmPackResult {
  files: NpmPackFileInfo[];
}

function isNpmPackResult(value: unknown): value is NpmPackResult {
  if (
    typeof value !== 'object' ||
    value === null ||
    !('files' in value) ||
    !Array.isArray((value as { files?: unknown }).files)
  ) {
    return false;
  }

  return (value as { files: unknown[] }).files.every(
    (file): file is NpmPackFileInfo =>
      typeof file === 'object' &&
      file !== null &&
      typeof (file as { path?: unknown }).path === 'string'
  );
}

function checkPublishSecurity(): void {
  console.log('🔍 Running comprehensive security check before npm publish...\n');
  
  const issues: SecurityIssue[] = [];
  
  // Get list of files that would be published
  let filesToPublish: string[];
  try {
    const output = execSync('npm pack --dry-run --json', { 
      cwd: projectRoot,
      encoding: 'utf-8' 
    });
    const packInfo = JSON.parse(output) as unknown;
    if (
      Array.isArray(packInfo) &&
      packInfo.length > 0 &&
      isNpmPackResult(packInfo[0])
    ) {
      filesToPublish = packInfo[0].files.map((file) => file.path);
      console.log(`📦 Checking ${filesToPublish.length} files that would be published to npm\n`);
    } else {
      throw new Error('Unexpected npm pack output format');
    }
  } catch (error) {
    console.error('Failed to get npm pack info, checking all files instead');
    filesToPublish = getAllFiles(projectRoot);
  }
  
  // Patterns that should never be in published files
  const dangerousPatterns = [
    // Environment files
    /\.env$/,
    /\.env\./,
    /\.env\..*$/,
    
    // Private keys and certificates
    /\.pem$/,
    /\.key$/,
    /\.cert$/,
    /\.crt$/,
    /\.p12$/,
    /\.pfx$/,
    
    // SSH and GPG keys
    /id_rsa/,
    /id_dsa/,
    /id_ecdsa/,
    /id_ed25519/,
    /\.ssh\//,
    /\.gnupg\//,
    
    // Cloud credentials
    /\.aws\//,
    /\.gcp\//,
    /\.azure\//,
    /credentials\.json$/,
    /service-account.*\.json$/,
    
    // Local config that shouldn't be published
    /\.vscode\//,
    /\.idea\//,
    /\.DS_Store$/,
    /Thumbs\.db$/,
    /\.local$/,
    /\.private$/,
    
    // Logs
    /\.log$/,
    /npm-debug\.log/,
    /yarn-error\.log/,
    
    // Test coverage
    /coverage\//,
    /\.nyc_output\//,
    
    // Build artifacts that shouldn't be in npm
    /\.cache\//,
    /\.parcel-cache\//,
    /\.next\//,
    /\.nuxt\//,
    /\.vuepress\//,
    /\.docusaurus\//,
    
    // Temp files
    /\.tmp$/,
    /\.temp$/,
    /~$/
  ];
  
  // Content patterns to search for secrets
  const secretPatterns = [
    // API Keys and tokens
    { pattern: /(?:api[_-]?key|apikey)\s*[:=]\s*['"]([^'"]{20,})['"]/, name: 'API Key' },
    { pattern: /(?:secret|token)\s*[:=]\s*['"]([^'"]{20,})['"]/, name: 'Secret/Token' },
    { pattern: /(?:password|passwd|pwd)\s*[:=]\s*['"]([^'"]+)['"]/, name: 'Password' },
    
    // AWS
    { pattern: /AKIA[0-9A-Z]{16}/, name: 'AWS Access Key' },
    { pattern: /aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*['"]([^'"]+)['"]/, name: 'AWS Secret' },
    
    // GitHub
    { pattern: /ghp_[a-zA-Z0-9]{36}/, name: 'GitHub Personal Token' },
    { pattern: /gho_[a-zA-Z0-9]{36}/, name: 'GitHub OAuth Token' },
    { pattern: /ghs_[a-zA-Z0-9]{36}/, name: 'GitHub App Token' },
    
    // Generic private keys
    { pattern: /-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----/, name: 'Private Key' },
    
    // Database URLs with credentials
    { pattern: /(?:mongodb|postgres|mysql|redis):\/\/[^:]+:[^@]+@/, name: 'Database URL with credentials' },
    
    // JWT secrets
    { pattern: /jwt[_-]?secret\s*[:=]\s*['"]([^'"]{10,})['"]/, name: 'JWT Secret' },
    
    // Stripe
    { pattern: /sk_(?:test|live)_[a-zA-Z0-9]{24,}/, name: 'Stripe Secret Key' },
    
    // SendGrid
    { pattern: /SG\.[a-zA-Z0-9_-]{22}\.[a-zA-Z0-9_-]{43}/, name: 'SendGrid API Key' },
    
    // Slack
    { pattern: /xox[baprs]-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24,}/, name: 'Slack Token' },
    
    // Generic Base64 encoded secrets (min 40 chars)
    { pattern: /[A-Za-z0-9+\/]{40,}={0,2}/, name: 'Potential Base64 Secret', lowConfidence: true }
  ];
  
  // Check each file that would be published
  for (const file of filesToPublish) {
    const fullPath = path.join(projectRoot, file);
    
    // Check filename patterns
    for (const pattern of dangerousPatterns) {
      if (pattern.test(file)) {
        issues.push({
          type: 'sensitive_path',
          file: file,
          pattern: pattern.toString()
        });
      }
    }
    
    // Check file contents
    if (fs.existsSync(fullPath) && fs.statSync(fullPath).isFile()) {
      try {
        const content = fs.readFileSync(fullPath, 'utf-8');
        const lines = content.split('\n');
        
        // Check for secrets in content
        lines.forEach((line, index) => {
          for (const secretPattern of secretPatterns) {
            const match = line.match(secretPattern.pattern);
            if (match) {
              // Skip if it's a variable reference or placeholder
              if (line.includes('process.env') || 
                  line.includes('${') || 
                  match[0].includes('xxxx') ||
                  match[0].includes('****') ||
                  match[0].includes('<') ||
                  match[0].includes('YOUR_') ||
                  match[0].includes('REPLACE_')) {
                continue;
              }
              
              if (!secretPattern.lowConfidence || line.toLowerCase().includes('key') || 
                  line.toLowerCase().includes('secret') || line.toLowerCase().includes('token')) {
                issues.push({
                  type: 'secret',
                  file: file,
                  line: index + 1,
                  content: line.trim().substring(0, 100),
                  pattern: secretPattern.name
                });
              }
            }
          }
        });
        
        // Special check for .env file references
        if (content.includes('.env') && !file.includes('test') && !file.includes('example')) {
          const envRefs = lines.filter((line, i) => 
            line.includes('.env') && !line.includes('gitignore')
          );
          if (envRefs.length > 0) {
            console.warn(`⚠️  Warning: ${file} references .env files`);
          }
        }
      } catch (err) {
        // Skip files we can't read
      }
    }
  }
  
  // Check if .npmignore or files field properly excludes sensitive files
  const npmignorePath = path.join(projectRoot, '.npmignore');
  const hasNpmignore = fs.existsSync(npmignorePath);
  const packageJson = JSON.parse(fs.readFileSync(path.join(projectRoot, 'package.json'), 'utf-8'));
  const hasFilesField = !!packageJson.files;
  
  if (!hasNpmignore && !hasFilesField) {
    console.warn('⚠️  Warning: No .npmignore file or "files" field in package.json');
    console.warn('   This could lead to unintended files being published\n');
  }
  
  // Report results
  if (issues.length > 0) {
    console.error('❌ SECURITY CHECK FAILED\n');
    console.error(`Found ${issues.length} potential security issues:\n`);
    
    // Group by type
    const byType = {
      env_file: issues.filter(i => i.type === 'env_file'),
      secret: issues.filter(i => i.type === 'secret'),
      sensitive_path: issues.filter(i => i.type === 'sensitive_path')
    };
    
    if (byType.sensitive_path.length > 0) {
      console.error('🚨 Sensitive files that would be published:');
      byType.sensitive_path.forEach(issue => {
        console.error(`   - ${issue.file} (matches: ${issue.pattern})`);
      });
      console.error('');
    }
    
    if (byType.secret.length > 0) {
      console.error('🔐 Potential secrets found:');
      byType.secret.forEach(issue => {
        console.error(`   - ${issue.file}:${issue.line} - ${issue.pattern}`);
        console.error(`     ${issue.content}`);
      });
      console.error('');
    }
    
    console.error('📋 How to fix:');
    console.error('   1. Add sensitive files to .npmignore');
    console.error('   2. Use the "files" field in package.json to explicitly list what to publish');
    console.error('   3. Move secrets to environment variables');
    console.error('   4. Never commit .env files or credentials to git\n');
    
    process.exit(1);
  } else {
    console.log('✅ Security check passed!');
    console.log('✅ No sensitive files or secrets detected in publish content');
    console.log(`✅ Checked ${filesToPublish.length} files\n`);
    
    if (hasFilesField) {
      console.log('👍 Using "files" field to control published content');
      console.log(`   Publishing: ${packageJson.files.join(', ')}\n`);
    }
  }
}

function getAllFiles(dir: string, files: string[] = []): string[] {
  const items = fs.readdirSync(dir, { withFileTypes: true });
  
  for (const item of items) {
    const fullPath = path.join(dir, item.name);
    if (item.isDirectory() && item.name !== 'node_modules' && !item.name.startsWith('.')) {
      getAllFiles(fullPath, files);
    } else if (item.isFile()) {
      files.push(path.relative(projectRoot, fullPath));
    }
  }
  
  return files;
}

// Run the check
checkPublishSecurity();