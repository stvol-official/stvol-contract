// scripts/check-secrets.js
const fs = require("fs");
const { execSync } = require("child_process");

const SENSITIVE_PATTERNS = [
  {
    name: "AWS Access Key",
    regex: /AKIA[0-9A-Z]{16}/g,
    description: "AWS Access Key ID detected",
  },
  {
    name: "AWS Secret Key",
    regex: /(?<!0x)[A-Za-z0-9/+=]{40}(?![a-fA-F0-9])/g,
    description: "Potential AWS Secret Access Key detected",
  },
  {
    name: "Mnemonic Phrase",
    regex:
      /(?:mnemonic|seed|phrase|words?)\s*[=:]\s*['"`]?([a-z]+\s+[a-z]+(?:\s+[a-z]+){10,23})['"`]?/gi,
    description: "Mnemonic phrase detected",
  },
  {
    name: "Mnemonic Phrase (No Keyword)",
    regex: /['"`]([a-z]+\s+[a-z]+(?:\s+[a-z]+){10,23})['"`]/g,
    description: "Potential mnemonic phrase detected",
  },
  {
    name: "API Key",
    regex: /(?:api[_-]?key|apikey)\s*[=:]\s*['"`]([^'"`\s]{20,})['"`]/gi,
    description: "API Key detected",
  },
  {
    name: "Database Password",
    regex: /(?:password|pwd|pass)\s*[=:]\s*['"`]([^'"`\s]{6,})['"`]/gi,
    description: "Database password detected",
  },
  {
    name: "JWT Token",
    regex: /eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*/g,
    description: "JWT Token detected",
  },
  {
    name: "Private Key",
    regex: /-----BEGIN[\s\w]*PRIVATE KEY-----/g,
    description: "Private key detected",
  },
  {
    name: "Database URL",
    regex: /(?:mongodb|mysql|postgresql|redis):\/\/[^\s\n\r'"]+/gi,
    description: "Database connection string detected",
  },
  {
    name: "Generic Secret",
    regex: /(?:secret|token|key)\s*[=:]\s*['"`]([^'"`\s]{16,})['"`]/gi,
    description: "Generic secret detected",
  },
];

const EXCLUDE_PATTERNS = [
  /node_modules/,
  /\.git/,
  /\.env\.example$/,
  /\.env\.template$/,
  /package-lock\.json$/,
  /yarn\.lock$/,
  /\.md$/,
  /scripts\/check-secrets\.js$/,
  /\.husky/,
  /\.openzeppelin/,
];

// allow list
const WHITELIST_VALUES = [
  "your-api-key-here",
  "placeholder-secret",
  "test-token",
  "dummy-password",
  "example-key",
];

// Ethereum address pattern
const ETH_ADDRESS_PATTERN = /^0x[a-fA-F0-9]{40}$/;

class SecretChecker {
  constructor() {
    this.findings = [];
  }

  // get staged files
  getStagedFiles() {
    try {
      const output = execSync("git diff --cached --name-only --diff-filter=ACM", {
        encoding: "utf8",
      });
      return output
        .trim()
        .split("\n")
        .filter((file) => file && file.length > 0);
    } catch (error) {
      console.log("📝 No staged files found or git command failed");
      return [];
    }
  }

  shouldExcludeFile(filePath) {
    return EXCLUDE_PATTERNS.some((pattern) => pattern.test(filePath));
  }

  isWhitelisted(value) {
    const cleanValue = value.replace(/['"`]/g, "").trim();

    if (ETH_ADDRESS_PATTERN.test(cleanValue)) {
      return true;
    }

    return WHITELIST_VALUES.some((whitelistValue) =>
      cleanValue.toLowerCase().includes(whitelistValue.toLowerCase()),
    );
  }

  checkFile(filePath) {
    if (this.shouldExcludeFile(filePath)) {
      return;
    }

    if (!fs.existsSync(filePath)) {
      return;
    }

    let content;
    try {
      content = fs.readFileSync(filePath, "utf8");
    } catch (error) {
      console.log(`⚠️  Could not read file: ${filePath}`);
      return;
    }

    const lines = content.split("\n");

    SENSITIVE_PATTERNS.forEach((pattern) => {
      lines.forEach((line, lineNumber) => {
        let match;
        const regex = new RegExp(pattern.regex.source, pattern.regex.flags);

        while ((match = regex.exec(line)) !== null) {
          const matchedValue = match[1] || match[0];

          if (ETH_ADDRESS_PATTERN.test(matchedValue)) {
            continue;
          }

          if (this.isWhitelisted(matchedValue)) {
            continue;
          }

          if (matchedValue.length < 8) {
            continue;
          }

          this.findings.push({
            file: filePath,
            line: lineNumber + 1,
            type: pattern.name,
            description: pattern.description,
            match: matchedValue.length > 50 ? matchedValue.substring(0, 50) + "..." : matchedValue,
            fullLine: line.trim(),
          });
        }
      });
    });
  }

  run() {
    console.log("🔍 Checking for sensitive information in staged files...\n");

    const stagedFiles = this.getStagedFiles();

    if (stagedFiles.length === 0) {
      console.log("✅ No staged files to check");
      return true;
    }

    console.log(`📋 Checking ${stagedFiles.length} staged file(s):\n`);

    stagedFiles.forEach((file) => {
      console.log(`   - ${file}`);
      this.checkFile(file);
    });

    console.log("");

    if (this.findings.length === 0) {
      console.log("✅ No sensitive information detected!");
      return true;
    }

    console.log("🚨 SENSITIVE INFORMATION DETECTED:\n");

    this.findings.forEach((finding, index) => {
      console.log(`${index + 1}. ${finding.file}:${finding.line}`);
      console.log(`   Type: ${finding.type}`);
      console.log(`   Description: ${finding.description}`);
      console.log(`   Match: ${finding.match}`);
      console.log(`   Line: ${finding.fullLine}`);
      console.log("");
    });

    console.log("🚫 COMMIT BLOCKED! Please address the issues above.\n");
    console.log("💡 Solutions:");
    console.log("   • Move secrets to environment variables (.env files)");
    console.log("   • Add .env to .gitignore");
    console.log("   • Use a secrets management service");
    console.log("   • If this is a false positive, add it to the whitelist\n");

    return false;
  }
}

if (require.main === module) {
  const checker = new SecretChecker();
  const success = checker.run();
  process.exit(success ? 0 : 1);
}

module.exports = SecretChecker;
