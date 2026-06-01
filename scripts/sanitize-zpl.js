#!/usr/bin/env node
"use strict";

/*
 * Saneia ZPL antes do envio para a impressora.
 *
 * Motivo: alguns geradores (ex.: etiquetas dos Correios) emitem ZPL invalido
 * que a ZD220 rejeita silenciosamente (o job sai da fila mas nada imprime):
 *   - coordenadas/dimensoes com casas decimais  -> ^PW850.88, ^FO610.88,76
 *   - largura de impressao acima do cabecote     -> ^PW > 832 dots (104mm @203dpi)
 *
 * O que faz:
 *   1. Trunca numeros decimais para inteiro APENAS nos parametros de comando,
 *      preservando o conteudo dos campos de dados ^FD/^FV (Data Matrix, Code128
 *      etc.), que pode conter pontos legitimos (ex.: coordenadas geograficas).
 *   2. Limita ^PW ao maximo fisico da ZD220 (832 dots).
 *
 * Uso:
 *   node scripts/sanitize-zpl.js <entrada.zpl> <saida.zpl>
 */

const fs = require("fs");

const MAX_PRINT_WIDTH = 832; // ZD220 203dpi: 104mm = 832 dots

function sanitizeCommandRegion(s) {
  // Trunca qualquer numero decimal para a parte inteira (850.88 -> 850).
  s = s.replace(/(\d+)\.\d+/g, "$1");
  // Limita a largura de impressao ao maximo do cabecote.
  s = s.replace(/\^PW(\d+)/g, (_m, n) => {
    const v = parseInt(n, 10);
    return "^PW" + (v > MAX_PRINT_WIDTH ? MAX_PRINT_WIDTH : v);
  });
  return s;
}

function sanitizeZpl(zpl) {
  let result = "";
  let rest = zpl;
  // Percorre o ZPL alternando entre regioes de comando (saneadas) e blocos de
  // dados ^FD/^FV ... ^FS (preservados byte a byte).
  while (rest.length > 0) {
    const m = rest.match(/\^F[DV]/i);
    if (!m) {
      result += sanitizeCommandRegion(rest);
      break;
    }
    const idx = m.index;
    // Regiao de comando antes do campo de dados: saneia.
    result += sanitizeCommandRegion(rest.slice(0, idx));
    const after = rest.slice(idx);
    const fsRel = after.search(/\^FS/i);
    if (fsRel === -1) {
      // Sem ^FS de fechamento: trata o restante como dado e preserva.
      result += after;
      break;
    }
    // Bloco de dados (inclui o marcador ^FD/^FV) preservado ate o ^FS.
    result += after.slice(0, fsRel);
    // Continua a partir do ^FS (volta a ser regiao de comando).
    rest = after.slice(fsRel);
  }
  return result;
}

function main() {
  const [, , inPath, outPath] = process.argv;
  if (!inPath || !outPath) {
    console.error("Uso: node scripts/sanitize-zpl.js <entrada.zpl> <saida.zpl>");
    process.exit(2);
  }
  // latin1 preserva bytes 128-255 (ZPL nao e UTF-8); evita corromper o arquivo.
  const zpl = fs.readFileSync(inPath, "latin1");
  const out = sanitizeZpl(zpl);
  fs.writeFileSync(outPath, out, "latin1");
}

main();
