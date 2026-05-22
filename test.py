import random

class RandomizedSet:
    def __init__(self):
        self.values = []
        self.value_to_index = {}

    def exists(self,val):
        return val in self.value_to_index

    def insert(self, val):
        if self.exists(val):
            return
        
        self.values.append(val)
        self.value_to_index[val] = len(self.values) - 1


    def remove(self, val):
        # problem: if we remove a value from value, theres going to be
        #   a hole inside self.values, but we can circumvent this by 
        #   swapping the last element with it

        if not self.exists(val):
            return

        remove_index = self.value_to_index[val]
        last_index = len(self.values) - 1
        last_value = self.values[last_index]

        self.values[remove_index] , self.values[last_index] = self.values[last_index], self.values[remove_index]
        self.values.pop()

        # adjust dicts
        self.value_to_index[last_value] = remove_index
        del self.value_to_index[val]



    def get_random(self):
        return random.choice(self.values)
