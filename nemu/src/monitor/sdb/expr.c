/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <isa.h>
#include <memory/vaddr.h>
#include <regex.h>

enum {
  TK_NOTYPE = 256,
  TK_EQ,
  TK_NEQ,
  TK_AND,
  TK_OR,
  TK_LE,
  TK_GE,
  TK_HEX,
  TK_NUM,
  TK_REG,
  TK_NEG,
  TK_DEREF,
};

static struct rule {
  const char *regex;
  int token_type;
} rules[] = {
  {" +", TK_NOTYPE},             // spaces
  {"0[xX][0-9a-fA-F]+", TK_HEX}, // hexadecimal numbers
  {"[0-9]+", TK_NUM},            // decimal numbers
  {"\\$[a-zA-Z0-9]+", TK_REG},   // register names
  {"==", TK_EQ},                 // equal
  {"!=", TK_NEQ},                // not equal
  {"&&", TK_AND},                // logical and
  {"\\|\\|", TK_OR},             // logical or
  {"<=", TK_LE},                 // less than or equal
  {">=", TK_GE},                 // greater than or equal
  {"<", '<'},                    // less than
  {">", '>'},                    // greater than
  {"\\+", '+'},                  // plus
  {"-", '-'},                    // minus
  {"\\*", '*'},                  // multiply
  {"/", '/'},                    // divide
  {"\\(", '('},                  // left parenthesis
  {"\\)", ')'},                  // right parenthesis
};

#define NR_REGEX ARRLEN(rules)

static regex_t re[NR_REGEX] = {};

void init_regex() {
  int i;
  char error_msg[128];
  int ret;

  for (i = 0; i < NR_REGEX; i ++) {
    ret = regcomp(&re[i], rules[i].regex, REG_EXTENDED);
    if (ret != 0) {
      regerror(ret, &re[i], error_msg, 128);
      panic("regex compilation failed: %s\n%s", error_msg, rules[i].regex);
    }
  }
}

typedef struct token {
  int type;
  char str[64];
} Token;

static Token tokens[1024] __attribute__((used)) = {};
static int nr_token __attribute__((used))  = 0;

static bool is_operator(int type) {
  return type == '+' || type == '-' || type == '*' || type == '/' ||
         type == TK_EQ || type == TK_NEQ || type == TK_AND || type == TK_OR ||
         type == '<' || type == '>' || type == TK_LE || type == TK_GE ||
         type == TK_NEG || type == TK_DEREF;
}

static bool make_token(char *e) {
  int position = 0;
  int i;
  regmatch_t pmatch;

  nr_token = 0;

  while (e[position] != '\0') {
    for (i = 0; i < NR_REGEX; i ++) {
      if (regexec(&re[i], e + position, 1, &pmatch, 0) == 0 && pmatch.rm_so == 0) {
        char *substr_start = e + position;
        int substr_len = pmatch.rm_eo;

        position += substr_len;

        if (rules[i].token_type == TK_NOTYPE) {
          break;
        }

        if (nr_token >= ARRLEN(tokens)) {
          printf("Expression too long: tokens buffer exceeded\n");
          return false;
        }

        tokens[nr_token].type = rules[i].token_type;
        int copy_len = substr_len < sizeof(tokens[nr_token].str) - 1 ? substr_len : sizeof(tokens[nr_token].str) - 1;
        strncpy(tokens[nr_token].str, substr_start, copy_len);
        tokens[nr_token].str[copy_len] = '\0';
        nr_token++;
        break;
      }
    }

    if (i == NR_REGEX) {
      printf("no match at position %d\n%s\n%*.s^\n", position, e, position, "");
      return false;
    }
  }

  /* Tag unary operators (negative and dereference) */
  for (i = 0; i < nr_token; i++) {
    if (tokens[i].type == '-') {
      if (i == 0 || is_operator(tokens[i - 1].type) || tokens[i - 1].type == '(') {
        tokens[i].type = TK_NEG;
      }
    } else if (tokens[i].type == '*') {
      if (i == 0 || is_operator(tokens[i - 1].type) || tokens[i - 1].type == '(') {
        tokens[i].type = TK_DEREF;
      }
    }
  }

  return true;
}

static int check_parentheses(int p, int q) {
  int count = 0;
  for (int i = p; i <= q; i++) {
    if (tokens[i].type == '(') count++;
    else if (tokens[i].type == ')') {
      count--;
      if (count < 0) return -1; // Unbalanced
    }
  }
  if (count != 0) return -1; // Unbalanced

  if (tokens[p].type != '(' || tokens[q].type != ')') return 0;

  count = 0;
  for (int i = p; i <= q; i++) {
    if (tokens[i].type == '(') count++;
    else if (tokens[i].type == ')') {
      count--;
      if (count == 0 && i < q) return 0; // Matched before reaching end
    }
  }
  return 1;
}

static int op_precedence(int type) {
  switch (type) {
    case TK_OR: return 1;
    case TK_AND: return 2;
    case TK_EQ:
    case TK_NEQ: return 3;
    case '<':
    case '>':
    case TK_LE:
    case TK_GE: return 4;
    case '+':
    case '-': return 5;
    case '*':
    case '/': return 6;
    case TK_NEG:
    case TK_DEREF: return 7;
    default: return 999;
  }
}

static int find_main_op(int p, int q) {
  int main_op = -1;
  int min_prec = 999;
  int in_paren = 0;

  for (int i = p; i <= q; i++) {
    if (tokens[i].type == '(') {
      in_paren++;
    } else if (tokens[i].type == ')') {
      in_paren--;
    } else if (in_paren == 0 && is_operator(tokens[i].type)) {
      int prec = op_precedence(tokens[i].type);
      // Unary operators are right-associative (pick leftmost)
      if (tokens[i].type == TK_NEG || tokens[i].type == TK_DEREF) {
        if (prec < min_prec) {
          min_prec = prec;
          main_op = i;
        }
      } else {
        // Binary operators are left-associative (pick rightmost)
        if (prec <= min_prec) {
          min_prec = prec;
          main_op = i;
        }
      }
    }
  }
  return main_op;
}

static word_t eval(int p, int q, bool *success) {
  if (!(*success)) return 0;

  if (p > q) {
    *success = false;
    printf("Syntax error: bad range [%d, %d]\n", p, q);
    return 0;
  }

  if (p == q) {
    word_t val = 0;
    if (tokens[p].type == TK_NUM) {
      char *endptr;
      val = strtoul(tokens[p].str, &endptr, 10);
    } else if (tokens[p].type == TK_HEX) {
      char *endptr;
      val = strtoul(tokens[p].str, &endptr, 16);
    } else if (tokens[p].type == TK_REG) {
      val = isa_reg_str2val(tokens[p].str, success);
      if (!(*success)) {
        printf("Unknown register '%s'\n", tokens[p].str);
      }
    } else {
      *success = false;
      printf("Syntax error: unexpected token '%s'\n", tokens[p].str);
    }
    return val;
  }

  int paren_stat = check_parentheses(p, q);
  if (paren_stat == -1) {
    *success = false;
    printf("Syntax error: mismatched parentheses in range [%d, %d]\n", p, q);
    return 0;
  }
  if (paren_stat == 1) {
    return eval(p + 1, q - 1, success);
  }

  int op = find_main_op(p, q);
  if (op == -1) {
    *success = false;
    printf("Syntax error: cannot find main operator in range [%d, %d]\n", p, q);
    return 0;
  }

  if (tokens[op].type == TK_NEG) {
    word_t val = eval(op + 1, q, success);
    return (word_t)(-(sword_t)val);
  } else if (tokens[op].type == TK_DEREF) {
    word_t addr = eval(op + 1, q, success);
    return vaddr_read(addr, 4);
  }

  word_t val1 = eval(p, op - 1, success);
  if (!(*success)) return 0;
  word_t val2 = eval(op + 1, q, success);
  if (!(*success)) return 0;

  switch (tokens[op].type) {
    case '+': return val1 + val2;
    case '-': return val1 - val2;
    case '*': return val1 * val2;
    case '/':
      if (val2 == 0) {
        printf("Runtime error: division by zero\n");
        *success = false;
        return 0;
      }
      return val1 / val2;
    case TK_EQ: return val1 == val2;
    case TK_NEQ: return val1 != val2;
    case TK_AND: return val1 && val2;
    case TK_OR: return val1 || val2;
    case '<': return val1 < val2;
    case '>': return val1 > val2;
    case TK_LE: return val1 <= val2;
    case TK_GE: return val1 >= val2;
    default:
      *success = false;
      printf("Syntax error: unhandled operator type %d\n", tokens[op].type);
      return 0;
  }
}

word_t expr(char *e, bool *success) {
  *success = true;
  if (e == NULL || *e == '\0') {
    *success = false;
    return 0;
  }

  if (!make_token(e)) {
    *success = false;
    return 0;
  }

  if (nr_token == 0) {
    *success = false;
    return 0;
  }

  return eval(0, nr_token - 1, success);
}
