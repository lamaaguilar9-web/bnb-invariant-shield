const fs = require('fs');
const path = require('path');
const solc = require('solc');

function findImports(importPath) {
    let fullPath = path.resolve(__dirname, 'contracts', importPath);
    if (fs.existsSync(fullPath)) {
        return { contents: fs.readFileSync(fullPath, 'utf8') };
    }
    const subPath = path.resolve(__dirname, 'contracts', path.basename(path.dirname(importPath)), path.basename(importPath));
    if (fs.existsSync(subPath)) {
        return { contents: fs.readFileSync(subPath, 'utf8') };
    }
    const directPath = path.resolve(__dirname, importPath);
    if (fs.existsSync(directPath)) {
        return { contents: fs.readFileSync(directPath, 'utf8') };
    }
    return { error: 'File not found: ' + importPath };
}

const shieldSource = fs.readFileSync(path.resolve(__dirname, 'contracts', 'BNBInvariantShield.sol'), 'utf8');
const receiverSource = fs.readFileSync(path.resolve(__dirname, 'contracts', 'BNBProtectedPoolReceiver.sol'), 'utf8');

const input = {
    language: 'Solidity',
    sources: {
        'BNBInvariantShield.sol': { content: shieldSource },
        'BNBProtectedPoolReceiver.sol': { content: receiverSource }
    },
    settings: {
        optimizer: {
            enabled: true,
            runs: 200
        },
        viaIR: true,
        outputSelection: {
            '*': {
                '*': ['*']
            }
        }
    }
};

const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));

if (output.errors) {
    let hasError = false;
    output.errors.forEach(err => {
        console.log(err.formattedMessage);
        if (err.severity === 'error') hasError = true;
    });
    if (hasError) {
        process.exit(1);
    }
}
console.log('SUCCESS: ALL CONTRACTS COMPILED CLEANLY WITH 0 ERRORS!');
